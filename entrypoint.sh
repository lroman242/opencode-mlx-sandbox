#!/usr/bin/env bash
# entrypoint.sh - container start
#
#   1. sync seed config -> ~/.config/opencode
#   2. apply the sandbox-owned config rewrites
#   3. git identity + safe.directory
#   4. start the socat forwarder when MLX_FORWARD=1
#   5. mark /workspace trusted for opencode
#   6. probe /v1/models
#   7. dispatch
#
# This is Linux (GNU userland). The disposable ~/.config/opencode copy is never
# written back to the host, so jq-rewriting keys here is safe.

set -u

CFG="$HOME/.config/opencode"
SEED="/opt/opencode-seed"
DATA="$HOME/.local/share/opencode"

MLX_FORWARD="${MLX_FORWARD:-0}"
MLX_HOST="${MLX_HOST:-127.0.0.1}"
MLX_PORT="${MLX_PORT:-8080}"
MLX_MODEL_ID="${MLX_MODEL_ID:-}"
OMS_YOLO="${OMS_YOLO:-0}"

log() { echo "[entrypoint] $*" >&2; }

# ---------------------------------------------------------------------------
# 1. sync seed -> config dir
#    mirror agent/ command/ plugin/ prompt/ skills/ with --delete; rest additive.
#    Never touch the data dir (sessions/ storage/ auth.json live there).
# ---------------------------------------------------------------------------
mkdir -p "$CFG" "$DATA"
if [ -d "$SEED" ]; then
  MIRROR="agent command plugin prompt skills"
  for d in $MIRROR; do
    if [ -d "$SEED/$d" ]; then
      mkdir -p "$CFG/$d"
      rsync -a --delete "$SEED/$d"/ "$CFG/$d"/
    fi
  done
  # everything else: additive (don't delete user/runtime files)
  rsync -a \
    --exclude 'agent/' --exclude 'command/' --exclude 'plugin/' \
    --exclude 'prompt/' --exclude 'skills/' \
    "$SEED"/ "$CFG"/
fi

# ---------------------------------------------------------------------------
# 2. config rewrites - deep-merge a patch over the copied opencode.json.
#    provider / model / small_model are deliberately left untouched.
# ---------------------------------------------------------------------------
CONF_JSON="$CFG/opencode.json"
[ -f "$CONF_JSON" ] || CONF_JSON="$CFG/opencode.jsonc"

apply_patch() {
  local patch="$1"
  local target="$CFG/opencode.json"
  local src="$CONF_JSON"
  if [ ! -f "$src" ]; then
    echo '{ "$schema": "https://opencode.ai/config.json" }' > "$target"
    src="$target"
  fi
  local tmp="$target.tmp"
  if jq --argjson patch "$patch" '. * $patch' "$src" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$target"
    [ "$src" != "$target" ] && rm -f "$src"
  else
    rm -f "$tmp"
    log "WARN: could not parse $src as JSON - skipping config rewrite"
  fi
}

if [ "$OMS_YOLO" = "1" ]; then
  log "yolo: tool approval disabled"
  apply_patch '{"permission":{"edit":"allow","bash":"allow","webfetch":"allow"}}'
fi

# ---------------------------------------------------------------------------
# 3. git identity + safe.directory
# ---------------------------------------------------------------------------
[ -n "${GIT_AUTHOR_NAME:-}" ]  && git config --global user.name  "$GIT_AUTHOR_NAME"
[ -n "${GIT_AUTHOR_EMAIL:-}" ] && git config --global user.email "$GIT_AUTHOR_EMAIL"
git config --global --add safe.directory /workspace
git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# 4. socat forwarder: make the host's 127.0.0.1:<port> reachable unchanged
# ---------------------------------------------------------------------------
if [ "$MLX_FORWARD" = "1" ]; then
  log "forwarding 127.0.0.1:${MLX_PORT} -> host.docker.internal:${MLX_PORT}"
  socat "TCP-LISTEN:${MLX_PORT},fork,reuseaddr" \
        "TCP:host.docker.internal:${MLX_PORT}" &
fi

# ---------------------------------------------------------------------------
# 5. mark /workspace trusted (best-effort; opencode has no explicit trust file
#    today - project data is created lazily under the data dir).
# ---------------------------------------------------------------------------
mkdir -p "$DATA/project"

# ---------------------------------------------------------------------------
# 6. probe /v1/models
# ---------------------------------------------------------------------------
if [ "$MLX_FORWARD" = "1" ]; then
  PROBE_HOST="127.0.0.1"
else
  PROBE_HOST="$MLX_HOST"
fi
probe_out=$(curl -fsS --max-time 5 "http://${PROBE_HOST}:${MLX_PORT}/v1/models" 2>/dev/null)
probe_id=$(printf '%s' "$probe_out" | jq -r '.data[0].id // empty' 2>/dev/null)
if [ -z "$probe_id" ]; then
  log "WARN: MLX server not reachable at ${PROBE_HOST}:${MLX_PORT} - run: opencode-mlx-sandbox mlx status"
elif [ -n "$MLX_MODEL_ID" ] && [ "$probe_id" != "$MLX_MODEL_ID" ]; then
  log "WARN: MLX server serves '$probe_id', expected '$MLX_MODEL_ID' - run: opencode-mlx-sandbox mlx status"
else
  log "MLX server OK: $probe_id"
fi

# ---------------------------------------------------------------------------
# 7. dispatch
# ---------------------------------------------------------------------------
if [ "${1:-}" = "sandbox-run" ]; then
  shift
  if [ "${1:-}" = "run" ]; then
    shift
    exec opencode run "$@"
  fi
  exec opencode "$@"
fi

exec "$@"