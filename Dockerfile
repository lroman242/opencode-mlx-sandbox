# opencode-mlx-sandbox container image (spec ss 4)
#
# Base already ships the `opencode` CLI. We only layer a dev toolchain and the
# sandbox glue on top. Build + run happen on Apple Silicon, so everything must
# resolve for linux/arm64 (buildkit passes TARGETARCH).

ARG OPENCODE_IMAGE_TAG=latest
FROM ghcr.io/anomalyco/opencode:${OPENCODE_IMAGE_TAG}

ARG TARGETARCH
ARG GO_VERSION=1.26.5
ARG UID=1000
ARG GID=1000

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- dev toolchain -------------------------------------------------------------
# Base is Debian/Ubuntu-derived (apt). If a future base is Alpine, switch to apk
# + a static Go tarball here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git make less jq rsync ripgrep socat \
      build-essential \
 && rm -rf /var/lib/apt/lists/*

# Go
RUN arch="${TARGETARCH:-arm64}" \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
      | tar -C /usr/local -xz \
 && /usr/local/go/bin/go version
ENV PATH="/usr/local/go/bin:/home/dev/go/bin:${PATH}"
ENV GOPATH="/home/dev/go"

# uv
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
 && uv --version

# task (go-task)
RUN sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin \
 && task --version

# --- non-root user -----------------------------------------------------------
# Map to the host UID/GID so the bind-mounted project stays sanely owned. If the
# base image already has a non-root user, remap it rather than adding a second.
RUN if getent passwd dev >/dev/null; then \
      groupmod -g "${GID}" dev 2>/dev/null || true ; \
      usermod  -u "${UID}" -g "${GID}" dev 2>/dev/null || true ; \
    else \
      getent group "${GID}" >/dev/null || groupadd -g "${GID}" dev ; \
      useradd -m -u "${UID}" -g "${GID}" -s /bin/bash dev ; \
    fi \
 && mkdir -p /home/dev/.config/opencode /home/dev/.local/share/opencode /home/dev/go \
 && chown -R "${UID}:${GID}" /home/dev

# --- opencode env: clean, offline TUI --------------------------------------
ENV OPENCODE_DISABLE_AUTOUPDATE=1 \
    DO_NOT_TRACK=1 \
    CI=1

# --- sandbox glue ----------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN printf '%s\n' '#!/usr/bin/env bash' 'set -e' \
      'echo "opencode: $(opencode --version 2>/dev/null || echo unknown)"' \
      'for t in go uv task rg jq git socat rsync make; do' \
      '  printf "%-8s %s\n" "$t" "$($t --version 2>/dev/null | head -n1 || echo missing)"' \
      'done' > /usr/local/bin/sandbox-versions \
 && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/sandbox-versions

COPY --chown=dev:dev .opencode-config/ /opt/opencode-seed/

USER dev
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]