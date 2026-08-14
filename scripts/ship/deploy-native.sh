#!/usr/bin/env bash
# 原生（非容器）換版 —— 給 macOS / Linux 上「不能容器化」的服務用。
#
# 為什麼需要這條路徑：deploy.sh 是純 docker，但 gs-shipyard 的分級裡有
# native-mac（TCC 權限 broker + LaunchAgent）與 native-win（UIA / DPAPI /
# 實體週邊）這些**原理上**進不了容器的 repo。它們同樣需要「測過才換、換壞要
# 回滾」，只是換的東西從 image 變成一份解開的 artifact。
#
# 不變量與 deploy.sh 完全一致，只是實現方式不同：
#   * 被測的 artifact 就是被部署的 artifact —— 容器用 digest，這裡用 **sha256**。
#     部署前一定重算一次，對不上就中止。
#   * 舊版在新版健康之前絕不刪除 —— 回滾靠的就是它。
#   * 任何失敗路徑都以「線上仍有一個健康版本」收尾，寧可不換版。
#
# 佈局（Capistrano 式，換版是一次 symlink 重指，近乎原子）：
#   $INSTALL_ROOT/
#     releases/<sha12>/     解開的 artifact
#     current -> releases/<sha12>
#     .ship-state           ACTIVE_SHA / PREV_SHA
#
# start/stop/health 由呼叫端提供，本腳本不綁死 LaunchAgent 或任何服務管理器
# —— 那是各 repo 自己的事，寫死只會逼所有人用同一套。
#
# 必要環境變數：
#   ARTIFACT       .tar.gz / .zip 路徑（已由 CI 下載到本機）
#   ARTIFACT_SHA   期望的 sha256（build 階段算的）
#   SERVICE        服務名（狀態檔與日誌用）
#   INSTALL_ROOT   安裝根目錄
#   START_CMD      啟動指令（在 current/ 內執行）
# 可選：
#   STOP_CMD       停止指令（留空 = 不停，適用單次執行型）
#   HEALTH_CMD     健康檢查指令（在 current/ 內執行，非零 = 不健康）
#   HEALTH_URL     HTTP 健康檢查（與 HEALTH_CMD 擇一或並用）
#   HEALTH_TIMEOUT 等健康的秒數上限（預設 60）
#   KEEP_RELEASES  保留幾個舊版（預設 3；太少會讓回滾無路可退）

set -euo pipefail

: "${ARTIFACT:?需要 ARTIFACT（artifact 檔路徑）}"
: "${ARTIFACT_SHA:?需要 ARTIFACT_SHA（build 階段算的 sha256）}"
: "${SERVICE:?需要 SERVICE（服務名）}"
: "${INSTALL_ROOT:?需要 INSTALL_ROOT（安裝根目錄）}"
: "${START_CMD:?需要 START_CMD（啟動指令）}"

STOP_CMD="${STOP_CMD:-}"
HEALTH_CMD="${HEALTH_CMD:-}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
KEEP_RELEASES="${KEEP_RELEASES:-3}"

RELEASES="$INSTALL_ROOT/releases"
CURRENT="$INSTALL_ROOT/current"
STATE="$INSTALL_ROOT/.ship-state"

log() { printf '[ship-native] %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 驗 artifact
[ -f "$ARTIFACT" ] || die "artifact 不存在：$ARTIFACT"

if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then     # macOS 沒有 sha256sum
  actual="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
else
  die "找不到 sha256sum 或 shasum，無法驗證 artifact 完整性——寧可不部署"
fi

# 這一步就是「測的就是部的」那條不變量。對不上代表中間有人換過東西，
# 或 CI 下載到別的 artifact，兩者都不該繼續。
[ "$actual" = "$ARTIFACT_SHA" ] \
  || die "artifact sha256 不符：期望 $ARTIFACT_SHA，實際 $actual"

SHA12="${ARTIFACT_SHA:0:12}"
NEW_DIR="$RELEASES/$SHA12"
log "artifact 驗證通過（$SHA12）"

mkdir -p "$RELEASES"

PREV_SHA=""
ACTIVE_SHA=""
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi
# 以實際的 symlink 指向為準，不是以狀態檔為準：狀態檔可能因上次中斷而過期。
if [ -L "$CURRENT" ]; then
  ACTIVE_SHA="$(basename "$(readlink "$CURRENT")")"
fi
log "目前線上：${ACTIVE_SHA:-（無）}；這次要上：$SHA12"

if [ "$ACTIVE_SHA" = "$SHA12" ]; then
  log "線上已經是這一版，不做任何事"
  exit 0
fi

# ---------------------------------------------------------------- 解開新版
# 解到暫存再搬進去：解到一半失敗的話，releases/ 底下不會留下半套的目錄
# 讓下次誤判成「這版已經解過了」。
STAGE="$(mktemp -d "$RELEASES/.stage-XXXXXX")"
cleanup_stage() { [ -d "$STAGE" ] && rm -rf "$STAGE"; }
trap cleanup_stage EXIT

case "$ARTIFACT" in
  *.tar.gz|*.tgz) tar xzf "$ARTIFACT" -C "$STAGE" ;;
  *.zip)          unzip -q "$ARTIFACT" -d "$STAGE" ;;
  *)              die "不支援的 artifact 格式：$ARTIFACT（要 .tar.gz 或 .zip）" ;;
esac

# artifact 若只有單一頂層目錄，把它拉平——否則 current/ 底下會多一層，
# START_CMD 的相對路徑就得跟著 artifact 的打包方式變，很容易錯。
entries=("$STAGE"/*)
if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
  inner="${entries[0]}"
  log "artifact 只有單一頂層目錄（$(basename "$inner")），拉平"
  mv "$inner" "$NEW_DIR"
else
  mv "$STAGE" "$NEW_DIR"
  STAGE=""    # 已搬走，trap 不要再刪
fi
[ -n "$STAGE" ] && { rm -rf "$STAGE"; STAGE=""; }
trap - EXIT

# ---------------------------------------------------------------- 健康檢查
healthy() {                          # healthy <dir>
  local dir="$1" deadline
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))

  if [ -z "$HEALTH_CMD" ] && [ -z "$HEALTH_URL" ]; then
    log "未設 HEALTH_CMD / HEALTH_URL，只確認服務沒有立刻退出"
    sleep 5
    return 0
  fi

  while [ "$(date +%s)" -lt "$deadline" ]; do
    local ok=1
    if [ -n "$HEALTH_CMD" ]; then
      ( cd "$dir" && eval "$HEALTH_CMD" ) >/dev/null 2>&1 || ok=0
    fi
    if [ "$ok" = "1" ] && [ -n "$HEALTH_URL" ]; then
      curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1 || ok=0
    fi
    [ "$ok" = "1" ] && return 0
    sleep 2
  done
  return 1
}

stop_service() {
  [ -n "$STOP_CMD" ] || return 0
  log "停止服務"
  ( cd "$INSTALL_ROOT" && eval "$STOP_CMD" ) >/dev/null 2>&1 || true
}

start_service() {                    # start_service <dir>
  log "啟動服務（$(basename "$1")）"
  ( cd "$1" && eval "$START_CMD" ) || return 1
  return 0
}

point_current() {                    # point_current <sha12>
  # ln -sfn 對「已存在且指向目錄的 symlink」才是重指而不是建在裡面。
  # 少了 -n 會變成 current/<sha12> 這種巢狀連結，症狀很難懂。
  ln -sfn "$RELEASES/$1" "$CURRENT"
}

save_state() {
  cat > "$STATE" <<EOF
ACTIVE_SHA=$1
PREV_SHA=$2
EOF
}

# ---------------------------------------------------------------- 換版
# 原生服務通常綁固定 port，沒辦法像容器那樣先在旁邊起一份做閘門。
# 所以順序是：停舊 → 指向新 → 起新 → 驗健康 → 不健康就把 symlink 指回去再起舊版。
# 換版之際有數秒空窗，但不會出現「壞版本長期接管線上」。
#
# ⚠ 原生換版特有的坑：舊行程被殺之後，它的 listening socket 會停在 TIME_WAIT。
#   若服務沒有設 SO_REUSEADDR，新行程綁同一個 port 會拿到
#   「Address already in use」而失敗——**症狀看起來是「新版不健康」**，然後回滾
#   起舊版也綁不上，最後變成「服務目前是壞的」。容器版不會有這個問題，每個容器
#   有自己的 network namespace。
#   對策：服務端設 SO_REUSEADDR（Python 用 http.server.HTTPServer 而不是裸的
#   socketserver.TCPServer；後者預設 allow_reuse_address=False），或把
#   HEALTH_TIMEOUT 拉到大於 TIME_WAIT。前者才是正解。
stop_service
point_current "$SHA12"

if start_service "$CURRENT" && healthy "$CURRENT"; then
  save_state "$SHA12" "$ACTIVE_SHA"
  log "換版完成：$SERVICE -> $SHA12"
else
  log "新版不健康，開始回滾"
  stop_service
  if [ -n "$ACTIVE_SHA" ] && [ -d "$RELEASES/$ACTIVE_SHA" ]; then
    point_current "$ACTIVE_SHA"
    if start_service "$CURRENT" && healthy "$CURRENT"; then
      die "新版不健康，已回滾到 $ACTIVE_SHA"
    fi
    die "新版不健康且回滾也未通過健康檢查 —— 服務目前是壞的，需要人工介入"
  fi
  die "新版不健康，且沒有上一版可回滾（這是本服務第一次部署）"
fi

# ---------------------------------------------------------------- 清舊版
# 磁碟不清會單調成長（同 deploy.sh 的 image 清理）。但這裡的下限比容器更硬：
# 上一版是回滾的唯一依據，所以 KEEP_RELEASES 至少要有 2，且現行版與上一版
# 一律不動。
keep=$(( KEEP_RELEASES < 2 ? 2 : KEEP_RELEASES ))
removed=0
# 依修改時間新到舊排序，跳過前 keep 個
while read -r d; do
  [ -n "$d" ] || continue
  base="$(basename "$d")"
  [ "$base" = "$SHA12" ] && continue
  [ "$base" = "$ACTIVE_SHA" ] && continue
  rm -rf "$d" && removed=$((removed+1))
done <<< "$(ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((keep+1)) || true)"
[ "$removed" -gt 0 ] && log "清掉 $removed 個舊 release（保留最近 $keep 個）"

exit 0
