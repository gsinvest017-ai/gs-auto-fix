#!/usr/bin/env bash
# 藍綠換版 —— 由 _reusable-ship.yml 的 deploy job 在自架 runner 上執行。
#
# 兩種策略：
#   proxy    反向代理上游切換。新舊兩色同時活著，Caddy 換上游是原子操作且會
#            graceful drain，真正零停機。需要 CADDY_ADMIN。
#   recreate 沒有代理時的作法。分兩段：
#              段一 先在暫時 port 起新版做健康閘門 —— 這段不碰線上，失敗零影響。
#              段二 過閘門才停舊起新，失敗自動用上一版 digest 回滾。
#            換版之際有數秒空窗，但不會出現「壞版本接管線上」。
#
# 不變量：
#   * 只用 digest 指稱 image。tag 會漂，測過的和部下去的必須是同一個 bit。
#   * 舊容器在新版健康之前絕不刪除 —— 回滾靠的就是它。
#   * 任何失敗路徑都以「線上仍有一個健康版本」收尾，寧可不換版。

set -euo pipefail

: "${IMAGE:?需要 IMAGE（image digest）}"
: "${SERVICE:?需要 SERVICE（服務名）}"
CONTAINER_PORT="${CONTAINER_PORT:-8000}"
PUBLISHED_PORT="${PUBLISHED_PORT:-0}"
HEALTH_PATH="${HEALTH_PATH:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
STRATEGY="${STRATEGY:-recreate}"
CADDY_ADMIN="${CADDY_ADMIN:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
STATE_DIR="${SHIP_STATE_DIR:-$HOME/.gs-ship}"
NET="${SHIP_NETWORK:-gs-ship}"

STATE="$STATE_DIR/$SERVICE.env"
mkdir -p "$STATE_DIR"

log() { printf '[ship] %s\n' "$*"; }
die() { printf '::error::%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置
if [ -n "${GHCR_TOKEN:-}" ]; then
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "${GHCR_USER:-x}" --password-stdin >/dev/null
fi
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# registry 短暫不可用不該讓部署整個掛掉，但「改用本機 image」的安全性取決於
# IMAGE 帶不帶 digest：帶 digest 時，本機同 digest 的 image 依定義就是同一份
# bits，用本機的沒有任何風險；只有 tag 的話就可能是舊版，要留 warning。
if ! docker pull "$IMAGE" >/dev/null 2>&1; then
  docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || die "無法從 registry 取得 $IMAGE，本機也沒有這份 image"
  case "$IMAGE" in
    *@sha256:*) log "pull 失敗，改用本機同 digest 的 image（bits 相同）" ;;
    *) printf '::warning::pull 失敗且 IMAGE 未帶 digest，改用本機 tag，可能不是最新版\n' ;;
  esac
fi
log "已取得 $IMAGE"

PREV_IMAGE=""
ACTIVE=""
# 注意：`[ -f x ] && . x` 在 set -e 下，條件為假時整條回傳 1 會直接終止腳本。
# 這個檔案裡所有「條件式副作用」都必須寫成完整的 if。
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi

# 以實際跑著的容器為準，不是以狀態檔為準：狀態檔可能因為上次中斷而過期，
# 但「誰在服務」這件事只有 docker 說了算。
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }
if running "${SERVICE}-blue"; then ACTIVE=blue
elif running "${SERVICE}-green"; then ACTIVE=green
else ACTIVE=""; fi

if [ "$ACTIVE" = "blue" ]; then NEW=green; else NEW=blue; fi
# ACTIVE 為空（首次部署，或兩色都被手動移掉）時，把「舊色」定成 NEW 的另一色，
# 免得組出 "svc-" 這種非法容器名讓回滾路徑爆掉。
if [ -n "$ACTIVE" ]; then OLD_C="${SERVICE}-${ACTIVE}"
elif [ "$NEW" = "blue" ]; then OLD_C="${SERVICE}-green"
else OLD_C="${SERVICE}-blue"; fi
NEW_C="${SERVICE}-${NEW}"
log "目前線上：${ACTIVE:-（無）}；這次要起：$NEW"

# ---------------------------------------------------------------- 健康探測
# 走一次性容器從 docker 網路內部探，不依賴宿主有沒有 curl，也不需要先曝 port。
probe() {                       # probe <host> <port>
  docker run --rm --network "$NET" curlimages/curl:8.11.1 \
    -fsS --max-time 5 "http://$1:$2${HEALTH_PATH}" >/dev/null 2>&1
}

wait_healthy() {                # wait_healthy <container> <port>
  if [ -z "$HEALTH_PATH" ]; then
    log "未設 health_path，略過 HTTP 探測（只確認容器沒有立刻退出）"
    sleep 5
    running "$1" && return 0
    docker logs --tail 50 "$1" 2>&1 || true
    return 1
  fi
  local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! running "$1"; then
      log "容器 $1 已退出"
      docker logs --tail 50 "$1" 2>&1 || true
      return 1
    fi
    probe "$1" "$2" && { log "$1 健康檢查通過"; return 0; }
    sleep 2
  done
  log "$1 在 ${HEALTH_TIMEOUT}s 內未通過健康檢查"
  docker logs --tail 50 "$1" 2>&1 || true
  return 1
}

start_container() {             # start_container <name> <image> [publish]
  local name="$1" image="$2" publish="${3:-}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  local args=(-d --name "$name" --network "$NET" --restart unless-stopped
              --label "gs-ship.service=$SERVICE" --label "gs-ship.image=$image")
  if [ -n "$publish" ]; then args+=(-p "$publish"); fi
  # EXTRA_ARGS 是呼叫端給的自由字串（掛載、-e 等），這裡刻意要斷字，故不加引號。
  # shellcheck disable=SC2086
  docker run "${args[@]}" $EXTRA_ARGS "$image" >/dev/null
}

save_state() {
  cat > "$STATE" <<EOF
ACTIVE=$1
PREV_IMAGE=$2
EOF
}

# 每次部署都 pull 一個新 digest，舊的沒人清就單調成長，最後把自架 runner 的
# 磁碟吃光——那不是「部署失敗」而是「runner 整台下線」，症狀跟本流水線完全
# 無關，很難聯想回來。
#
# 保留規則就是回滾契約：現行版 + 上一版。再舊的沒有任何用途。
# docker rmi 對「正在被容器使用」的 image 會失敗，所以就算保留清單算錯，
# 也不會把線上服務的 image 刪掉——那是這裡最後一道保險，故一律吞錯。
prune_old_images() {                # prune_old_images <keep_current> <keep_prev>
  local keep_cur="$1" keep_prev="${2:-}"
  local repo="${keep_cur%%@*}"; repo="${repo%%:*}"
  [ -n "$repo" ] || return 0

  local line id dig ref removed=0
  while read -r line; do
    [ -n "$line" ] || continue
    id="${line%% *}"; dig="${line##* }"
    [ "$dig" = "<none>" ] && continue
    ref="${repo}@${dig}"
    [ "$ref" = "$keep_cur" ] && continue
    [ -n "$keep_prev" ] && [ "$ref" = "$keep_prev" ] && continue
    if docker rmi "$id" >/dev/null 2>&1; then
      removed=$((removed+1))
    fi
  done <<< "$(docker image ls --no-trunc --filter "reference=${repo}" \
                --format '{{.ID}} {{.Digest}}' 2>/dev/null || true)"

  [ "$removed" -gt 0 ] && log "清掉 $removed 個不再需要的舊 image（保留現行版與上一版）"
  return 0
}

# ---------------------------------------------------------------- proxy
if [ "$STRATEGY" = "proxy" ]; then
  [ -n "$CADDY_ADMIN" ] || die "strategy=proxy 需要 caddy_admin"

  start_container "$NEW_C" "$IMAGE"
  if ! wait_healthy "$NEW_C" "$CONTAINER_PORT"; then
    docker rm -f "$NEW_C" >/dev/null 2>&1 || true
    die "新版健康檢查未通過，線上維持 ${ACTIVE:-原狀}，未換版"
  fi

  # Caddy 那端要有一個帶 @id 的 reverse_proxy handler（見 docs/ship-pipeline.md）。
  # PATCH 是原子的：換完之後新連線走新色，舊連線由 Caddy 自然收尾。
  body="[{\"dial\":\"${NEW_C}:${CONTAINER_PORT}\"}]"
  if ! curl -fsS -X PATCH "$CADDY_ADMIN/id/${SERVICE}-upstreams" \
        -H 'Content-Type: application/json' -d "$body" >/dev/null; then
    docker rm -f "$NEW_C" >/dev/null 2>&1 || true
    die "Caddy 上游切換失敗，線上維持 ${ACTIVE:-原狀}"
  fi
  log "Caddy 上游已切到 $NEW_C"

  # 切換後再從代理外側驗一次：確認換的是對的上游，而不是「新容器自己健康」而已。
  sleep 2
  if [ -n "$HEALTH_PATH" ] && ! probe "$NEW_C" "$CONTAINER_PORT"; then
    curl -fsS -X PATCH "$CADDY_ADMIN/id/${SERVICE}-upstreams" \
      -H 'Content-Type: application/json' \
      -d "[{\"dial\":\"${OLD_C}:${CONTAINER_PORT}\"}]" >/dev/null || true
    docker rm -f "$NEW_C" >/dev/null 2>&1 || true
    die "換版後驗證失敗，已把上游切回 $OLD_C"
  fi

  if [ -n "$ACTIVE" ]; then
    docker stop "$OLD_C" >/dev/null 2>&1 || true
    log "舊色 $OLD_C 已停（保留容器，供人工回滾）"
  fi
  # 注意順序：先 save_state 落地回滾點，再清舊 image。反過來的話，清到一半
  # 掛掉就會留下「狀態檔還指著已被刪除的 PREV_IMAGE」——回滾路徑會爛掉。
  save_state "$NEW" "$IMAGE"
  prune_old_images "$IMAGE" "$PREV_IMAGE"
  log "零停機換版完成：$SERVICE -> $NEW ($IMAGE)"
  exit 0
fi

# ---------------------------------------------------------------- recreate
[ "$PUBLISHED_PORT" != "0" ] || die "strategy=recreate 需要 published_port"

# 段一：閘門。線上完全不動，壞版本在這裡就被擋掉。
GATE="${SERVICE}-gate"
start_container "$GATE" "$IMAGE"
if ! wait_healthy "$GATE" "$CONTAINER_PORT"; then
  docker rm -f "$GATE" >/dev/null 2>&1 || true
  die "新版起不來，線上維持 ${ACTIVE:-原狀}，未換版"
fi
docker rm -f "$GATE" >/dev/null 2>&1 || true
log "閘門通過，開始換版"

# 段二：換版。這段有數秒空窗，失敗就用 PREV_IMAGE 回滾。
if [ -n "$ACTIVE" ]; then
  docker stop "$OLD_C" >/dev/null 2>&1 || true
fi

if start_container "$NEW_C" "$IMAGE" "${PUBLISHED_PORT}:${CONTAINER_PORT}" \
   && wait_healthy "$NEW_C" "$CONTAINER_PORT"; then
  if [ -n "$ACTIVE" ]; then docker rm -f "$OLD_C" >/dev/null 2>&1 || true; fi
  save_state "$NEW" "$IMAGE"
  prune_old_images "$IMAGE" "$PREV_IMAGE"
  log "換版完成：$SERVICE -> $NEW ($IMAGE)"
  exit 0
fi

log "換版後健康檢查失敗，開始回滾"
docker rm -f "$NEW_C" >/dev/null 2>&1 || true
if [ -n "$PREV_IMAGE" ]; then
  if start_container "$OLD_C" "$PREV_IMAGE" "${PUBLISHED_PORT}:${CONTAINER_PORT}" \
     && wait_healthy "$OLD_C" "$CONTAINER_PORT"; then
    die "新版不健康，已回滾到 $PREV_IMAGE"
  fi
  die "新版不健康且回滾也未通過健康檢查 —— 服務目前是壞的，需要人工介入"
fi
die "新版不健康，且沒有上一版 digest 可回滾（這是本服務第一次部署）"
