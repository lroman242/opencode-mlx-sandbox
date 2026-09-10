#!/usr/bin/env bash
# install.sh - installer / upgrader (spec ss 9). Re-runnable.

set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd -P)
CONFIG_DIR="${OMS_CONFIG_DIR:-$HOME/.config/opencode-mlx-sandbox}"
BIN_DIR="$HOME/.local/bin"
export OMS_CONFIG_DIR="$CONFIG_DIR"

say() { echo "install: $*"; }
die() { echo "install: $*" >&2; exit 1; }

# 1. prerequisites
command -v docker >/dev/null 2>&1 || \
  die "docker not found - install Docker Desktop: https://www.docker.com/products/docker-desktop/"
command -v jq >/dev/null 2>&1 || \
  die "jq not found - install it: brew install jq"

# 2. dirs
mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/lib" "$BIN_DIR"

# 3. build assets
cp "$REPO_DIR/Dockerfile"     "$CONFIG_DIR/Dockerfile"
cp "$REPO_DIR/entrypoint.sh"  "$CONFIG_DIR/entrypoint.sh"
cp "$REPO_DIR/.dockerignore"  "$CONFIG_DIR/.dockerignore"
cp "$REPO_DIR"/lib/*.sh       "$CONFIG_DIR/lib/"
chmod +x "$CONFIG_DIR"/lib/*.sh "$CONFIG_DIR/entrypoint.sh"

# 4. .env
if [ ! -f "$CONFIG_DIR/.env" ]; then
  cp "$REPO_DIR/.env.example" "$CONFIG_DIR/.env"
  say "wrote $CONFIG_DIR/.env"
fi

# 5. launcher
install -m 0755 "$REPO_DIR/bin/opencode-mlx-sandbox" "$BIN_DIR/opencode-mlx-sandbox"
say "installed $BIN_DIR/opencode-mlx-sandbox"

# read build pins from .env (fallback to Dockerfile defaults)
env_val() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONFIG_DIR/.env" 2>/dev/null \
    | sed 's/[[:space:]]\{1,\}#.*$//;s/[[:space:]]*$//' | grep -v '^$' | tail -n1
}
OPENCODE_IMAGE_TAG=$(env_val OPENCODE_IMAGE_TAG); OPENCODE_IMAGE_TAG="${OPENCODE_IMAGE_TAG:-latest}"
GO_VERSION=$(env_val GO_VERSION); GO_VERSION="${GO_VERSION:-1.26.5}"

# 6. stage host config
say "staging host opencode config"
"$CONFIG_DIR/lib/seed-opencode-config.sh"

# 7. build image
say "building opencode-mlx-sandbox:latest"
docker build -t opencode-mlx-sandbox:latest \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  --build-arg OPENCODE_IMAGE_TAG="$OPENCODE_IMAGE_TAG" \
  --build-arg GO_VERSION="$GO_VERSION" \
  "$CONFIG_DIR"

# 8. PATH check
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) say "WARNING: $BIN_DIR is not on your PATH - add it to your shell profile" ;;
esac

say "done. cd into a project and run: opencode-mlx-sandbox"