#!/usr/bin/env bash
# deploy.sh 的端到端驗證 —— 需要本機有可用的 docker daemon。
#
# 驗三件事，每一件都是「壞掉會直接害到生產」的路徑：
#   1. 首次部署要能起來並對外服務
#   2. 壞版本要在**閘門**就被擋掉，且線上舊版完全不受影響（零風險路徑）
#   3. 換版成功時顏色要真的交替，且服務內容換成新版
#
# CI 不跑這支（GitHub runner 上起 daemon-in-daemon 太脆）；這是人在本機或在
# 自架 runner 上手動跑的驗證。用法：bash tests/e2e_ship_deploy.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$HERE/../scripts/ship/deploy.sh"
SVC="shiptest"
PORT=18099
WORK="$(mktemp -d)"
export SHIP_STATE_DIR="$WORK/state"
export SHIP_NETWORK="shiptest-net"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

cleanup() {
  docker rm -f "${SVC}-blue" "${SVC}-green" "${SVC}-gate" >/dev/null 2>&1 || true
  docker network rm "$SHIP_NETWORK" >/dev/null 2>&1 || true
  docker rmi -f shiptest:v1 shiptest:v2 shiptest:broken >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- 準備 image
build_app() {                      # build_app <tag> <版本字串>
  # 不要寫成 `local a=$1 b=$WORK/$a` —— 同一個 local 敘述的所有引數是「先全部
  # 展開、才逐一賦值」，$a 在展開時還不存在，set -u 下會直接爆 unbound variable。
  local tag="$1"
  local ver="$2"
  local dir="$WORK/${tag//:/-}"
  mkdir -p "$dir"
  cat > "$dir/app.py" <<PY
import http.server, socketserver
VER = "$ver"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = VER.encode()
        self.send_response(200 if self.path in ("/healthz", "/") else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
socketserver.TCPServer(("", 8000), H).serve_forever()
PY
  cat > "$dir/Dockerfile" <<'DF'
FROM python:3.12-alpine
WORKDIR /app
COPY app.py .
CMD ["python", "app.py"]
DF
  docker build -q -t "$tag" "$dir" >/dev/null
}

build_broken() {
  local dir="$WORK/broken"; mkdir -p "$dir"
  cat > "$dir/Dockerfile" <<'DF'
FROM python:3.12-alpine
CMD ["python", "-c", "import sys; sys.stderr.write('boom: 設定檔缺 API_KEY\n'); sys.exit(3)"]
DF
  docker build -q -t shiptest:broken "$dir" >/dev/null
}

echo "== 準備測試 image =="
build_app shiptest:v1 "version-1"
build_app shiptest:v2 "version-2"
build_broken
docker pull -q curlimages/curl:8.11.1 >/dev/null

run_deploy() {                     # run_deploy <image>
  IMAGE="$1" SERVICE="$SVC" PUBLISHED_PORT="$PORT" CONTAINER_PORT=8000 \
  HEALTH_PATH=/healthz HEALTH_TIMEOUT=40 STRATEGY=recreate \
  bash "$DEPLOY"
}

serving() { curl -fsS --max-time 5 "http://localhost:$PORT/" 2>/dev/null || true; }
color_of() { docker inspect -f '{{.State.Running}}' "${SVC}-$1" 2>/dev/null || echo false; }

# ---------------------------------------------------------------- 1 首次部署
echo "== 1. 首次部署 =="
if run_deploy shiptest:v1 >"$WORK/1.log" 2>&1; then
  [ "$(serving)" = "version-1" ] && ok "服務回應 version-1" || bad "服務內容不對：$(serving)"
  [ "$(color_of blue)" = "true" ] && ok "起在 blue" || bad "blue 沒在跑"
else
  bad "首次部署失敗"; sed 's/^/    /' "$WORK/1.log"
fi

# ---------------------------------------------------------------- 2 壞版本
echo "== 2. 壞版本必須在閘門被擋，線上不受影響 =="
if run_deploy shiptest:broken >"$WORK/2.log" 2>&1; then
  bad "壞版本竟然部署成功了"
else
  ok "壞版本被擋下（deploy.sh 非零離開）"
  grep -q "未換版" "$WORK/2.log" && ok "訊息明確指出未換版" || bad "沒有講清楚未換版"
  [ "$(serving)" = "version-1" ] && ok "線上仍是 version-1（零影響）" || bad "線上被弄壞了：$(serving)"
  [ "$(color_of blue)" = "true" ] && ok "blue 仍在跑" || bad "blue 被動到了"
  docker inspect "${SVC}-gate" >/dev/null 2>&1 && bad "閘門容器沒清掉" || ok "閘門容器已清除"
fi

# ---------------------------------------------------------------- 3 正常換版
echo "== 3. 換到新版，顏色交替 =="
if run_deploy shiptest:v2 >"$WORK/3.log" 2>&1; then
  [ "$(serving)" = "version-2" ] && ok "服務已換成 version-2" || bad "服務沒換：$(serving)"
  [ "$(color_of green)" = "true" ] && ok "新色 green 在跑" || bad "green 沒起來"
  docker inspect "${SVC}-blue" >/dev/null 2>&1 && bad "舊色沒清掉" || ok "舊色 blue 已清除"
  grep -q "PREV_IMAGE=shiptest:v2" "$SHIP_STATE_DIR/$SVC.env" \
    && ok "狀態檔記下這次的 image" || bad "狀態檔沒更新"
else
  bad "換版失敗"; sed 's/^/    /' "$WORK/3.log"
fi

# ---------------------------------------------------------------- 4 回滾
# 最要命的一段：過得了閘門、上線後才掛。這時線上已經沒有健康版本，
# 全靠狀態檔裡的 PREV_IMAGE 把上一版拉回來。
# 用「第一次起得來、第二次就掛」的 image 來精準命中這條路徑
#（閘門那次啟動留下 marker，正式那次看到 marker 就自殺）。
echo "== 4. 過閘門後才掛 → 自動回滾到上一版 =="
dir="$WORK/flaky"; mkdir -p "$dir"
cat > "$dir/app.py" <<'PY'
import http.server, os, socketserver, sys
if os.path.exists("/state/started"):
    sys.stderr.write("boom: 第二次啟動時炸掉\n"); sys.exit(4)
os.makedirs("/state", exist_ok=True)
open("/state/started", "w").close()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "5")
        self.end_headers(); self.wfile.write(b"flaky")
    def log_message(self, *a): pass
socketserver.TCPServer(("", 8000), H).serve_forever()
PY
cat > "$dir/Dockerfile" <<'DF'
FROM python:3.12-alpine
WORKDIR /app
COPY app.py .
CMD ["python", "app.py"]
DF
docker build -q -t shiptest:flaky "$dir" >/dev/null
docker volume create shiptest-state >/dev/null

if IMAGE=shiptest:flaky SERVICE="$SVC" PUBLISHED_PORT="$PORT" CONTAINER_PORT=8000 \
   HEALTH_PATH=/healthz HEALTH_TIMEOUT=25 STRATEGY=recreate \
   EXTRA_ARGS="-v shiptest-state:/state" bash "$DEPLOY" >"$WORK/4.log" 2>&1; then
  bad "上線後掛掉的版本竟然算部署成功"
else
  ok "部署判定為失敗"
  grep -q "已回滾" "$WORK/4.log" && ok "訊息指出已回滾" || bad "沒有回滾訊息"
  [ "$(serving)" = "version-2" ] && ok "線上被救回 version-2" || bad "線上沒救回來：$(serving)"
fi
docker volume rm -f shiptest-state >/dev/null 2>&1 || true
docker rmi -f shiptest:flaky >/dev/null 2>&1 || true

echo
printf '通過 %d，失敗 %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
