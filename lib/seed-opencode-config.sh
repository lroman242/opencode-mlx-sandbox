#!/usr/bin/env bash
# lib/seed-opencode-config.sh
#
# Stage the host's ~/.config/opencode -> $CONFIG_DIR/.opencode-config/ so it can
# be baked into the image. Run by install.sh and by
# `opencode-mlx-sandbox rebuild`.
#
# Runs on the macOS host. macOS may ship openrsync (limited flags), so stick to
# `-a --delete --exclude` or fall back to cp -R + prune. No rsync-3-only options.

set -u

CONFIG_DIR="${OMS_CONFIG_DIR:-$HOME/.config/opencode-mlx-sandbox}"
SRC="${OPENCODE_CONFIG_SRC:-$HOME/.config/opencode}"
DST="$CONFIG_DIR/.opencode-config"

# read SEED_SKIP_SKILLS from .env if not already set
if [ -z "${SEED_SKIP_SKILLS+x}" ] && [ -f "$CONFIG_DIR/.env" ]; then
  SEED_SKIP_SKILLS=$(sed -n 's/^[[:space:]]*SEED_SKIP_SKILLS[[:space:]]*=[[:space:]]*//p' "$CONFIG_DIR/.env" | tail -n1)
fi
SEED_SKIP_SKILLS="${SEED_SKIP_SKILLS:-}"

if [ ! -d "$SRC" ]; then
  echo "seed: host opencode config not found at $SRC" >&2
  echo "seed: creating an empty $DST (opencode will start with defaults)" >&2
  rm -rf "$DST"
  mkdir -p "$DST"
  exit 0
fi

mkdir -p "$DST"

EXCLUDES="node_modules .git __pycache__ *.map"

if command -v rsync >/dev/null 2>&1; then
  set -- -a --delete
  for e in $EXCLUDES; do set -- "$@" --exclude "$e"; done
  rsync "$@" "$SRC"/ "$DST"/
else
  rm -rf "$DST"
  mkdir -p "$DST"
  cp -R "$SRC"/. "$DST"/
  find "$DST" \( -name node_modules -o -name .git -o -name __pycache__ \) -prune -exec rm -rf {} + 2>/dev/null || true
  find "$DST" -name '*.map' -type f -delete 2>/dev/null || true
fi

for s in $SEED_SKIP_SKILLS; do
  [ -n "$s" ] || continue
  rm -rf "$DST/skills/$s"
  echo "seed: skipped skill '$s'" >&2
done

echo "seed: staged $SRC -> $DST" >&2