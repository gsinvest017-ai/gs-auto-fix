#!/usr/bin/env bash
# deploy-native.sh 的端到端驗證 —— 不需要 docker，只需要 python3。
#
# 驗五件事，每一件都是「壞掉會直接害到生產」的路徑：
#   1. 首次部署要能起來並對外服務
#   2. artifact sha256 對不上要中止，且**什麼都不要裝**（測的就是部的）
#   3. 換版成功時 current 要指向新版，且上一版要留著
#   4. 新版不健康要自動回滾，線上救回上一版
#   5. 舊 release 要被清掉，但現行版與上一版一律保留
#
# 用法：bash tests/e2e_ship_deploy_native.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HERE/../scripts/ship/deploy-native.sh"
WORK="$(mktemp -d)"
ROOT="$WORK/install"
SVC="nativetest"

# port 動態挑（同容器版的理由：這支會跑在自架 runner 上，而那台也是部署目標）
pick_free_port() {
  local p
  for p in $(seq 18200 18299); do
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
    exec 3>&- 2>/dev/null || true
  done
  echo "18200"
}
PORT="$(pick_free_port)"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

cleanup() {
  [ -f "$ROOT/app.pid" ] && kill "$(cat "$ROOT/app.pid")" 2>/dev/null || true
  pkill -f "nativetest-app" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# ---------------------------------------------------------------- 建 artifact
# 服務是一支最小 http server。第二個參數 healthy=no 時 /healthz 回 500，
# 用來精準命中「起得來但不健康」這條路徑——那跟「根本起不來」是不同的失效。
make_artifact() {                    # make_artifact <版本字串> <healthy:yes|no>
  local ver="$1" healthy="$2"
  local d="$WORK/src-$ver"; mkdir -p "$d"
  cat > "$d/app.py" <<PY
import http.server, socketserver, sys
VER, HEALTHY = "$ver", "$healthy" == "yes"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz" and not HEALTHY:
            self.send_response(500); self.end_headers(); return
        b = VER.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
socketserver.TCPServer(("", int(sys.argv[1])), H).serve_forever()
PY
  local tgz="$WORK/$ver.tar.gz"
  tar czf "$tgz" -C "$d" .
  echo "$tgz"
}

# 啟動指令刻意用 nohup + pidfile：原生服務沒有 docker 幫忙管生命週期，
# 這也是實務上最常見的形狀。
START="nohup python3 app.py $PORT > $ROOT/app.log 2>&1 & echo \$! > $ROOT/app.pid; sleep 1"
STOP="[ -f $ROOT/app.pid ] && kill \$(cat $ROOT/app.pid) 2>/dev/null; rm -f $ROOT/app.pid; sleep 1; true"

run_deploy() {                       # run_deploy <artifact> <sha>
  ARTIFACT="$1" ARTIFACT_SHA="$2" SERVICE="$SVC" INSTALL_ROOT="$ROOT" \
  START_CMD="$START" STOP_CMD="$STOP" \
  HEALTH_URL="http://127.0.0.1:$PORT/healthz" HEALTH_TIMEOUT=20 \
  KEEP_RELEASES=2 \
  bash "$DEPLOY"
}

serving() { curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true; }
current_sha() { basename "$(readlink "$ROOT/current" 2>/dev/null || echo none)"; }

echo "使用 port $PORT"
mkdir -p "$ROOT"

# ---------------------------------------------------------------- 1 首次部署
echo "== 1. 首次部署 =="
A1="$(make_artifact v1 yes)"; S1="$(sha_of "$A1")"
if run_deploy "$A1" "$S1" >"$WORK/1.log" 2>&1; then
  [ "$(serving)" = "v1" ] && ok "服務回應 v1" || bad "服務內容不對：$(serving)"
  [ "$(current_sha)" = "${S1:0:12}" ] && ok "current 指向 v1" || bad "current 指錯：$(current_sha)"
else
  bad "首次部署失敗"; sed 's/^/    /' "$WORK/1.log"
fi

# ---------------------------------------------------------------- 2 sha 不符
echo "== 2. artifact sha256 對不上要中止，且什麼都不裝 =="
A2="$(make_artifact v2 yes)"; S2="$(sha_of "$A2")"
before=$(ls -1 "$ROOT/releases" | wc -l)
if run_deploy "$A2" "0000000000000000000000000000000000000000000000000000000000000000" \
     >"$WORK/2.log" 2>&1; then
  bad "sha 不符竟然還是部署了"
else
  ok "sha 不符被擋下"
  grep -q "sha256 不符" "$WORK/2.log" && ok "訊息指出 sha 不符" || bad "沒講清楚原因"
  [ "$(ls -1 "$ROOT/releases" | wc -l)" = "$before" ] \
    && ok "releases/ 沒有被塞進半套東西" || bad "留下了殘骸"
  [ "$(serving)" = "v1" ] && ok "線上仍是 v1（零影響）" || bad "線上被動到：$(serving)"
fi

# ---------------------------------------------------------------- 3 正常換版
echo "== 3. 換到新版，上一版保留 =="
if run_deploy "$A2" "$S2" >"$WORK/3.log" 2>&1; then
  [ "$(serving)" = "v2" ] && ok "服務已換成 v2" || bad "服務沒換：$(serving)"
  [ "$(current_sha)" = "${S2:0:12}" ] && ok "current 指向 v2" || bad "current 指錯"
  [ -d "$ROOT/releases/${S1:0:12}" ] && ok "上一版 v1 保留（回滾靠它）" \
    || bad "上一版被刪了——回滾會失效"
else
  bad "換版失敗"; sed 's/^/    /' "$WORK/3.log"
fi

# ---------------------------------------------------------------- 4 回滾
echo "== 4. 新版不健康 → 自動回滾 =="
A3="$(make_artifact v3 no)"; S3="$(sha_of "$A3")"
if run_deploy "$A3" "$S3" >"$WORK/4.log" 2>&1; then
  bad "不健康的版本竟然算部署成功"
else
  ok "部署判定為失敗"
  grep -q "已回滾" "$WORK/4.log" && ok "訊息指出已回滾" || bad "沒有回滾訊息"
  [ "$(serving)" = "v2" ] && ok "線上被救回 v2" || bad "線上沒救回來：$(serving)"
  [ "$(current_sha)" = "${S2:0:12}" ] && ok "current 指回 v2" || bad "current 沒指回去"
fi

# ---------------------------------------------------------------- 5 清舊版
echo "== 5. 舊 release 清理，現行版與上一版保留 =="
A4="$(make_artifact v4 yes)"; S4="$(sha_of "$A4")"
if run_deploy "$A4" "$S4" >"$WORK/5.log" 2>&1; then
  [ -d "$ROOT/releases/${S4:0:12}" ] && ok "現行版 v4 在" || bad "現行版不見了"
  [ -d "$ROOT/releases/${S2:0:12}" ] && ok "上一版 v2 保留" || bad "上一版被清掉了"
  n=$(ls -1d "$ROOT/releases"/*/ 2>/dev/null | wc -l)
  [ "$n" -le 3 ] && ok "release 數量收斂（$n 個，KEEP_RELEASES=2）" \
    || bad "沒有清理，累積了 $n 個"
else
  bad "第四次部署失敗"; sed 's/^/    /' "$WORK/5.log"
fi

echo
printf '通過 %d，失敗 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
