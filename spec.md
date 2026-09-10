# opencode-mlx-sandbox — spec

`opencode-mlx-sandbox` runs the **[opencode](https://opencode.ai) coding agent
inside a disposable, per-folder Docker container**, driven by a **local MLX model
served on the host machine**.

Goal: a fully local coding agent. In the default setup the model runs on the
host under Apple's MLX runtime and nothing leaves the machine; the agent runs
sandboxed in a container that can only see the one project folder you point it
at, and can never write back to your global agent configuration. (A remote MLX
endpoint is also supported — see `--host`.)

```bash
cd ~/Projects/anything
opencode-mlx-sandbox                                  # default model, host MLX server
opencode-mlx-sandbox --model mlx-community/Qwen2.5-Coder-32B-Instruct-4bit
opencode-mlx-sandbox --model ~/models/my-4bit-mlx --yolo
opencode-mlx-sandbox shell                            # a bash shell in the container instead
```

The name is also the launcher command, the Docker image
(`opencode-mlx-sandbox:latest`), and the container/volume prefix (`oms-`).

**Given (target-machine facts, not to be re-derived):**

- MLX and `mlx-lm` are installed on the host, inside a Python virtualenv at
  `~/.venv-mlx` — activated with `source ~/.venv-mlx/bin/activate`.
- The host is macOS on Apple Silicon with Docker Desktop.

This tool therefore does not provision, install, or configure the MLX runtime.
It activates that venv, launches `mlx_lm.server` with the requested model (or
connects to one already running), and makes that server reachable from inside
the container — the opencode provider config that targets it is the user's own
(§5.1). The venv path is overridable via `MLX_VENV` in `.env`.

---

## 1. Concept

Three moving parts:

1. **Host MLX server** — an OpenAI-compatible HTTP server (`mlx_lm.server`)
   loaded with the model given via `--model`. Long-lived, shared across every
   project folder. Started by this tool when it runs on `localhost` and is not
   already up; otherwise the tool just connects. Runs on the host because MLX is
   Apple-Silicon-only; the container is Linux and just needs an HTTP client.

2. **The container** — a Linux image with the `opencode` CLI plus a normal dev
   toolchain. opencode dials the address in the user's own provider config
   (typically `http://127.0.0.1:<port>/v1`); the entrypoint forwards that to the
   host server (§6). One container per project folder.

3. **Config seeding** — a full copy of your global `~/.config/opencode` (agents,
   commands, plugins, prompts, skills, config — including the MLX provider block)
   is **baked into the image** and synced into the container at start. There is
   no bind mount of the host config, so the sandboxed agent cannot modify it.

Each project folder also gets its own persistent Docker volume for opencode
session/message history, so `opencode` session resume works between runs.

Runs on macOS + Apple Silicon (where MLX lives) with Docker Desktop, which
resolves `host.docker.internal` to the host automatically. A remote or
non-Apple MLX endpoint is supported via `--host` / `--port` (the tool then only
connects, never starts a server).

---

## 2. Repository layout

```
bin/opencode-mlx-sandbox          the launcher (bash): host server manager + `docker run`
install.sh                        installer / upgrader
Dockerfile                        the container image
entrypoint.sh                     container start: sync config, wire opencode -> MLX, dispatch
lib/seed-opencode-config.sh       stage ~/.config/opencode -> .opencode-config/
lib/mlx-server.sh                 start / stop / health / logs for the host MLX server
.env.example                      global defaults, copied to ~/.config/opencode-mlx-sandbox/.env
README.md
```

Paths used at runtime:

```
~/.config/opencode-mlx-sandbox/           config dir (created by install.sh)
  ├── .env                                global defaults
  ├── Dockerfile, entrypoint.sh, .dockerignore, lib/*.sh   build assets (copied by install.sh)
  ├── .opencode-config/                   staged host config (docker build context input)
  └── run/
      ├── mlx.pid                         host server PID (only when we started it)
      ├── mlx.log                         host server stdout/stderr
      └── mlx.json                        {model, model_id, opts, host, port, token, started_at, last_used, keep_alive, managed}
```

### 2.1 Host tooling & portability (macOS)

Every `bin/` and `lib/` script runs on the macOS host — BSD userland, and the
system `/bin/bash` is **3.2**. Write for that, not for GNU/Linux:

| Don't rely on (GNU/Linux) | Use instead (macOS-safe) |
|---|---|
| bash 4+ features — `declare -A`, `${x,,}`, `mapfile`, `**` globstar | bash 3.2 constructs only; or `#!/usr/bin/env bash` **and** guard on `BASH_VERSINFO` with a clear error asking for a Homebrew bash |
| `sha1sum` / `sha256sum` | `shasum -a 1` / `shasum -a 256` (or `/sbin/md5`) |
| `realpath`, `readlink -f` | `cd "$dir" && pwd -P` |
| `timeout N cmd` | poll loop with `SECONDS` / epoch math (`date +%s`) |
| `date -d <string>` | store epoch seconds (`date +%s`) in `mlx.json`; compare integers |
| `sed -i` | `sed -i ''` — or prefer not editing in place |
| `ss` | `lsof -nP -iTCP:$PORT -sTCP:LISTEN` for the port-in-use check |
| `grep -P` | BSD `grep` — POSIX classes / `grep -E` only |

Host dependencies the launcher needs beyond the base system:

- **Docker Desktop** — provides the `docker` CLI and the built-in
  `host.docker.internal` DNS name (so `--add-host …:host-gateway` is belt-and-
  braces; keep it, it is harmless on Docker Desktop ≥ 4.x).
- **`jq`** — used to read/write `mlx.json` and to build the `docker run` env.
  Not shipped by macOS; `install.sh` checks for it and points at
  `brew install jq` if missing. (`python3` from the Command Line Tools is an
  acceptable fallback if the implementation prefers it.)
- Token generation uses `openssl rand -hex 24` (always present on macOS).

The container image is unaffected — it is Linux and carries its own GNU
toolchain (§4).

---

## 3. Host MLX server — `lib/mlx-server.sh`

A small process supervisor over the host's existing `mlx-lm` install.
Subcommands: `ensure`, `start`, `stop`, `status`, `logs`.

Every invocation of an `mlx-*` / `mlx_lm.*` command is prefixed with venv
activation:

```
source "${MLX_VENV:-$HOME/.venv-mlx}/bin/activate"
```

run in the same subshell as the command. If the venv or `mlx_lm.server` is not
found when a server needs to be started, fail with a message naming `MLX_VENV`.
(Connect-only paths — a server already up, or a non-loopback `--host` — never
touch the venv.)

### 3.1 Resolving `--model`

- `org/name` (looks like a HuggingFace repo id) → passed straight to
  `mlx_lm.server`, which downloads it into the HF cache on demand.
- An absolute path or `~`-path to a directory → treated as a local MLX model,
  used as-is.
- Omitted → `MLX_MODEL` from `.env`, default
  `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`.

### 3.2 Starting

```
( source "${MLX_VENV:-$HOME/.venv-mlx}/bin/activate"
  exec mlx_lm.server \
    --model <resolved> \
    --model-name <MLX_MODEL_ID> \
    --host <HOST> \
    --port <PORT> \
    [--api-key <TOKEN>] \
    [extra --mlx-opts...] )
```

Backgrounded; record `mlx.pid`, stream output to `mlx.log`, write `mlx.json`
with `managed: true`. `--mlx-opts` is appended verbatim; `--model-opts k=v,...`
uses the **exact `mlx_lm.server` long-option names** as keys — each `k=v` becomes
`--k v` (`max-kv-size=8192` → `--max-kv-size 8192`, `temp=0.7` → `--temp 0.7`),
a bare `k` becomes the flag `--k`. No renaming or alias layer. Both the resolved
model and the effective option set are stored in `mlx.json` so the match check
(§3.4) can tell whether a running server already matches the request.

**Model id is pinned.** Because the tool serves exactly one model, it starts the
server with `--model-name "$MLX_MODEL_ID"` where `MLX_MODEL_ID` is a fixed,
predictable value derived from `--model` — the basename with any `org/` prefix
or path stripped (e.g. `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` →
`Qwen2.5-Coder-7B-Instruct-4bit`). So the id opencode must use is always known
up front and documented ("use the basename"), no reading it back required. The
health check (§3.3) still asserts `/v1/models` reports exactly that id.
(Verify the running mlx-lm exposes `--model-name`; if a given version does not,
fall back to reading the id from `/v1/models` and surfacing it via `mlx status`.)

- `HOST`: `--host`, else `MLX_HOST` from `.env`, else `127.0.0.1`.
- `PORT`: `--port`, else `MLX_PORT` from `.env`, else `8080`.
- A random bearer `TOKEN` (`openssl rand -hex 24`) is generated per start unless
  `--mlx-no-auth`, stored in `mlx.json`, and passed into the container as
  `MLX_API_KEY` for the user's
  provider config to reference (§6). For a server we did not start, no token is
  generated — supply one via `--env` if that endpoint needs it.
- If `HOST` is not a loopback address, the tool assumes the server is externally
  managed: it only health-checks, never starts or stops it (`mlx.json` gets
  `managed: false`).
- Before starting, check the port with `lsof -nP -iTCP:$PORT -sTCP:LISTEN`
  (§2.1). If it is held and `/v1/models` there is not a matching MLX server,
  fail loudly.

### 3.3 Health check

Poll `GET http://<HOST>:<PORT>/v1/models` (curl) in a loop until it lists a
model, or `MLX_START_TIMEOUT` seconds elapse (default 300) — measured with
`SECONDS` / `date +%s`, not the GNU `timeout` binary (§2.1). Assert the reported
id equals the pinned `MLX_MODEL_ID` (§3.2); mismatch is a hard error. `mlx
status` also prints it so the user can copy the exact `mlx/<MLX_MODEL_ID>` string
into their opencode config.

### 3.4 One model, no switching

The tool never runs, stops, or reloads a model to satisfy a request. `ensure`,
the entry point the launcher calls:

- **Nothing answering at `<HOST>:<PORT>`**, loopback host → start the server with
  the resolved `--model` and options.
- **Nothing answering**, remote host → error (cannot start a remote server).
- **A server already answering**, and its model **and** option set match the
  request → reuse it, no matter who started it.
- **A server already answering** with a **different model, `--model-opts`, or
  `--mlx-opts`** → **exit with a non-zero error** naming the mismatch (running
  vs. requested). No prompt, no reload. The user resolves it by matching the
  request to the running server, or by `opencode-mlx-sandbox mlx stop` (managed
  servers only) and re-running.

"Match" ignores fields the running server cannot report — the comparison is
against what is recorded in `mlx.json` for a managed server; for a server we did
not start, only the reported model id (`/v1/models`) is checked.

### 3.5 Stopping and idle shutdown

- `stop`: only acts on a server with `managed: true`. SIGTERM the PID, SIGKILL
  after a grace period, delete `run/` files.
- `--mlx-keep-alive <dur>` / `MLX_KEEP_ALIVE` (e.g. `30m`): the launcher writes
  `last_used` (epoch seconds, §2.1) to `mlx.json` on every container start; a
  subsequent `mlx start` / `mlx status` (or a user-installed launchd sweep, §11)
  stops a managed server whose `now - last_used` exceeds the window. Default:
  stays up until an explicit `mlx stop`.

### 3.6 `status` output

Model, `MLX_MODEL_ID`, host, port, PID (if managed), uptime, keep-alive setting,
`managed` flag, and the live result of the `/v1/models` probe (or the last error
line from `mlx.log`).

---

## 4. Container image — `Dockerfile`

Base: **`ghcr.io/anomalyco/opencode`** (tag pinned via the `OPENCODE_IMAGE_TAG`
build arg, default `latest`). opencode is already present in this image; the
Dockerfile only layers the dev toolchain and sandbox glue on top.

The build and every `docker run` happen on Apple Silicon, so the base image (and
the Go / `task` / `uv` binaries the Dockerfile pulls) must resolve for
`linux/arm64`. If the base image is amd64-only, either build with
`--platform linux/amd64` (Rosetta emulation — slow) or pick an arm64 opencode
image; confirm during implementation.

No Node.js / npm — not needed once opencode comes from the base image.

| Layered on top | Notes                                                                                |
|---|--------------------------------------------------------------------------------------|
| Go | `GO_VERSION` build arg (default 1.26.5)                                              |
| uv, git, make, task, ripgrep, jq, rsync, curl, less, socat | standard dev toolchain + host-server forwarder + `jq` for the config rewrites (§6.1) |
| `sandbox-versions` | script printing opencode + tool versions                                             |
| `entrypoint.sh` | copied to `/usr/local/bin`, set as `ENTRYPOINT`                                      |

`--yolo` is not a shim or CLI flag — the entrypoint applies it as a config
rewrite (§6.1).

- Runs as non-root user `dev`, with `UID`/`GID` build args mapped to the host
  user so the bind-mounted project stays sanely owned. (If the base image ships
  its own non-root user, rename/remap it to `dev` + `UID`/`GID` rather than
  adding a second user.)
- `ENV OPENCODE_DISABLE_AUTOUPDATE=1` and telemetry/onboarding opt-out
  pre-written so the TUI starts clean and offline.
- `COPY --chown=dev:dev .opencode-config/ /opt/opencode-seed/` — the staged host
  config (see §5). This is a baked copy, **not** a mount.
- The base image's package manager (`apt` if it is Debian/Ubuntu-based) is used
  for the toolchain; if it is Alpine, adjust to `apk` and static Go tarball.
  Confirm the base distro during implementation.

---

## 5. Config seeding — `lib/seed-opencode-config.sh`

Copies the host `~/.config/opencode` **in full** into `.opencode-config/` inside
the config dir (which is the `docker build` context). Run by `install.sh` and by
`opencode-mlx-sandbox rebuild`.

The opencode config holds no third-party API keys (the model is local and needs
none), so the whole tree is copied verbatim — `opencode.json`, `agent/`,
`command/`, `prompt/`, `plugin/`, `skills/`, `AGENTS.md`, and anything else the
user keeps there.

Only two adjustments:

- **Bulk / VCS excludes** for image size: `node_modules`, `.git`,
  `__pycache__`, `*.map`.
- `SEED_SKIP_SKILLS` (`.env`, space-separated) drops named skill directories —
  use it for large host-only toolchains.

Runs on the host, so keep to portable copy primitives — recent macOS ships
`openrsync`, whose flag support differs from GNU `rsync`. Stick to
`-a --delete --exclude`, or use `cp -R` plus an explicit prune pass; do not
depend on rsync 3-only options.

At container start the seed is rsynced into `~/.config/opencode/`: `agent/`,
`command/`, `plugin/`, `prompt/`, `skills/` mirrored with `--delete`, everything
else additive.

### 5.1 The provider is the user's config

Pointing opencode at the MLX server — the `provider` block, the `model` /
`small_model` selection, per-model options — lives entirely in the user's
`~/.config/opencode`. These keys are **never** generated or rewritten by this
tool (the entrypoint's config rewrites, §6.1, deliberately exclude them). The
user is expected to have an MLX provider configured there, e.g.:

```jsonc
{
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" }
    }
  },
  "model": "mlx/<model-basename>"
}
```

`<model-basename>` is the `--model` value with any `org/` prefix or path
stripped (§3.2) — the tool pins the served id to exactly that, and `mlx status`
prints it. `baseURL`'s port must match `--port` / `MLX_PORT` (§6); host stays
`127.0.0.1` for a local server (the container forwards it).

The sandbox's only job is to make the address that config already uses resolve,
from inside the container, to the host MLX server (§6), and to hand over the
bearer token if one is required.

---

## 6. Reaching the host server from the container — `entrypoint.sh`

The container cannot reach the host's `127.0.0.1`. Rather than rewrite the
endpoint in the config, the entrypoint starts a lightweight TCP forwarder so the
**same address the config uses** works unchanged:

```
socat TCP-LISTEN:${MLX_PORT},fork,reuseaddr TCP:host.docker.internal:${MLX_PORT}
```

- Runs in the background for the life of the container. `socat` is added to the
  image toolchain (§4).
- Bound inside the container only. `host.docker.internal` is reachable via
  `--add-host host.docker.internal:host-gateway`.
- Started only when `--host` / `MLX_HOST` is a loopback address (`MLX_FORWARD=1`).
  For a non-loopback `--host`, the user's config is expected to name that same
  host, which already resolves from the container, so no forwarder runs
  (`MLX_FORWARD=0`).
- **The user's config must agree with `--host` / `--port` (`MLX_HOST` /
  `MLX_PORT`)**: same port always (the forwarder listens on exactly one), and for
  a remote server the same host. Defaults line up at `127.0.0.1:8080`; change one
  side and change the other. The entrypoint probe (§6.2) warns on a detectable
  mismatch.

Auth: if the launcher generated a bearer token (managed server, no
`--mlx-no-auth`), it is exported into the container as `MLX_API_KEY`. The user's
provider config can reference it (`"apiKey": "{env:MLX_API_KEY}"`), or omit auth
entirely with `--mlx-no-auth`.

### 6.1 In-place config rewrites

The `~/.config/opencode/` inside the container is a **disposable copy** — synced
from the baked seed on every start, never bind-mounted, never written back to the
host. So the entrypoint is free to `jq`-rewrite individual keys in that copy
before launching opencode, without affecting the user's real config.

This is the mechanism for sandbox-policy params the tool *does* own:

| Trigger | Rewrite applied to the container's `opencode.json` |
|---|---|
| `--yolo` | merge a permissive `permission` block (e.g. `{ "edit": "allow", "bash": "allow", "webfetch": "allow" }` — confirm current key names, §11) |
| always | nothing else — `provider`, `model`, `small_model` are left exactly as the user set them (§5.1) |

Rewrites are a deep-merge over the copied file (`jq '. * $patch'`), so keys the
user set that are not in the patch are preserved. If a future need arises to
override more (e.g. disable a specific plugin in the sandbox), it goes through
this same table — one documented place, copy only.

### 6.2 Full `entrypoint.sh` responsibilities

1. rsync `/opt/opencode-seed/` → `~/.config/opencode/`: mirror `agent/`,
   `command/`, `plugin/`, `prompt/`, `skills/` with `--delete`; everything else
   additive; never touch `sessions/`, `storage/`, `auth.json` in the data dir.
2. Apply the §6.1 config rewrites to the copied `opencode.json`.
3. git identity from `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`; mark `/workspace`
   and `*` as `safe.directory`.
4. Start the `socat` forwarder when `MLX_FORWARD=1`.
5. Mark `/workspace` as a trusted project for opencode so no trust prompt appears.
6. Probe `/v1/models` — at `127.0.0.1:${MLX_PORT}` when `MLX_FORWARD=1` (through
   the forwarder), else at `${MLX_HOST}:${MLX_PORT}`. If it fails, or reports an
   id other than `${MLX_MODEL_ID}`, print a warning pointing at
   `opencode-mlx-sandbox mlx status` but continue.
7. Dispatch: `sandbox-run <args>` → `opencode "$@"` (TUI), or
   `opencode run "<prompt>"` for the `run` subcommand. Anything else (`bash`,
   `sandbox-versions`) runs verbatim.

---

## 7. Session persistence

Per project folder: a Docker named volume `oms-<hash>` where `<hash>` is the
first 12 hex chars of `printf %s "<abs path>" | shasum -a 1` (§2.1), labelled
`oms.path=<abs path>`, mounted at `/home/dev/.local/share/opencode` (opencode's
data directory — sessions, message history). It survives across runs so session
resume works. Global config is re-synced from the image on every start, so
`rebuild` propagates config edits to all projects.

- `--fresh` — remove this folder's volume and start clean.
- `--no-persist` — fully ephemeral, no volume.
- `opencode-mlx-sandbox volume ls` — list all session volumes (by path label).
- `opencode-mlx-sandbox stop` — remove the container (volume kept).
- `opencode-mlx-sandbox volume rm` — remove every session volume.

---

## 8. CLI — `bin/opencode-mlx-sandbox`

```
opencode-mlx-sandbox [PATH] [OPTIONS] [-- <opencode args>]
opencode-mlx-sandbox <SUBCOMMAND> [PATH] [OPTIONS]
```

`PATH` is positional, defaults to `.`, and is mounted at `/workspace`.

### Subcommands

| | |
|---|---|
| _(none)_ | ensure image + host MLX server, then start an interactive opencode session |
| `run` | non-interactive: `opencode run "<prompt>"` (prompt goes after `--`) |
| `rebuild` | re-stage host config + rebuild the image, then exit |
| `build` | build the image if missing, then exit |
| `shell` | start `bash` in the container instead of opencode |
| `mlx start` | start / ensure the host MLX server for `--model`, then exit |
| `mlx stop` | stop the host MLX server (only if this tool started it) |
| `mlx status` | model + served id, host, port, PID, uptime, keep-alive, managed flag, `/v1/models` health |
| `mlx logs` | tail `~/.config/opencode-mlx-sandbox/run/mlx.log` |
| `models` | list MLX models found in the HuggingFace cache |
| `stop` | remove the container for `PATH` |
| `versions` | print opencode + tool versions from the image |
| `ps` | list `oms-` containers |
| `rm` | force-remove all `oms-` containers |
| `volume ls` / `volume rm` | list / remove all per-project session volumes |
| `rmi` | remove the `opencode-mlx-sandbox:latest` image |

### Options

| | |
|---|---|
| `--model ID\|PATH` | HuggingFace repo id or local MLX model dir (default `MLX_MODEL`, `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`) |
| `--host HOST` | MLX server host (default `MLX_HOST`, else `127.0.0.1`); non-loopback ⇒ connect-only |
| `--port N` | MLX server port (default `MLX_PORT`, else `8080`) |
| `--mlx-opts "..."` | raw flags passed through to `mlx_lm.server` verbatim |
| `--model-opts k=v,...` | `k=v` list using `mlx_lm.server`'s own long-option names → `--k v` (e.g. `max-kv-size=8192,temp=0.7`) |
| `--mlx-keep-alive DUR` | stop a managed server after this idle time (e.g. `30m`; default `MLX_KEEP_ALIVE`, else: until `mlx stop`) |
| `--mlx-no-auth` | do not generate / require a bearer token |
| `--yolo` | run opencode with tool approval disabled |
| `--rebuild` | re-stage + rebuild, then continue into the session |
| `--env PATH` | extra env file (`KEY=VALUE` lines: git identity, `MLX_API_KEY`, …) |
| `--fresh` | ignore (and wipe) the persisted session volume for this run |
| `--no-persist` | do not create / use a session volume |
| `--name NAME` | container name (default `oms-<folder>-<hash>`) |
| `-h, --help` | |

Everything after `--` is passed straight to `opencode` (or to `bash` with
`shell`).

### Launch sequence (no subcommand)

1. Parse args; resolve `PATH` → absolute `TARGET` (error if not a directory).
2. `lib/mlx-server.sh ensure --model <ID> --host <HOST> --port <PORT>
   [--mlx-opts … --model-opts …]` — resolve the model, derive `MLX_MODEL_ID`
   (the basename), start the server if the host is loopback and nothing is
   answering (else connect / error per §3.4), wait for health and assert the
   served id. Set `MLX_FORWARD=1` when `<HOST>` is loopback (else `0`).
3. Ensure the image (`docker build` if missing, or on `--rebuild`).
4. Create / refresh the session volume (unless `--no-persist`; wipe on `--fresh`).
5. Assemble `docker run`: `--rm -i` (+ `-t` when a TTY), mount
   `TARGET:/workspace` (workdir `/workspace`), mount the session volume,
   `--add-host host.docker.internal:host-gateway`, and `-e` for
   `MLX_FORWARD`, `MLX_HOST` (the real server host, used for the probe when
   `MLX_FORWARD=0`), `MLX_PORT`, `MLX_API_KEY`, `MLX_MODEL_ID`, `OMS_YOLO`,
   plus any env-file values (`GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`).
6. `exec docker run … opencode-mlx-sandbox:latest sandbox-run <passthru>`.

---

## 9. install.sh

1. Check host prerequisites: `docker` (Docker Desktop) and `jq` on `PATH` —
   error with `brew install jq` / a Docker Desktop link if missing (§2.1).
2. `mkdir -p ~/.config/opencode-mlx-sandbox ~/.local/bin`.
3. Copy `Dockerfile`, `entrypoint.sh`, `.dockerignore`, `lib/*.sh` into the
   config dir.
4. Copy `.env.example` → `.env` if absent.
5. `install -m 0755 bin/opencode-mlx-sandbox ~/.local/bin/`.
6. Run `lib/seed-opencode-config.sh` to stage `~/.config/opencode`.
7. `docker build -t opencode-mlx-sandbox:latest --build-arg UID=$(id -u)
   --build-arg GID=$(id -g) --build-arg OPENCODE_IMAGE_TAG=$OPENCODE_IMAGE_TAG
   --build-arg GO_VERSION=$GO_VERSION ~/.config/opencode-mlx-sandbox`
   (`OPENCODE_IMAGE_TAG` / `GO_VERSION` read from `.env`, with the Dockerfile
   defaults as fallback).
8. Warn if `~/.local/bin` is not on `PATH`.

Re-runnable to upgrade. `opencode-mlx-sandbox rebuild` re-runs steps 6–7.

---

## 10. .env.example

```sh
# opencode-mlx-sandbox global defaults -> ~/.config/opencode-mlx-sandbox/.env
# All optional. Only non-empty KEY=VALUE lines take effect.

# Model used when --model is omitted.
MLX_MODEL=mlx-community/Qwen2.5-Coder-7B-Instruct-4bit

# Host MLX server.
MLX_VENV=~/.venv-mlx         # virtualenv where mlx-lm is installed
MLX_HOST=127.0.0.1
MLX_PORT=8080
MLX_START_TIMEOUT=300
# MLX_KEEP_ALIVE=30m

# Image build pins (used by install.sh / `rebuild`).
OPENCODE_IMAGE_TAG=latest  # tag of ghcr.io/anomalyco/opencode to build FROM
GO_VERSION=1.26.5

# Skills to skip when seeding (space-separated dir names).
SEED_SKIP_SKILLS=

# git identity inside the container.
GIT_AUTHOR_NAME=
GIT_AUTHOR_EMAIL=
```

There is no model API key — the model is local.

---

## 11. Open questions / v2

- **opencode auto-approve**: confirm the exact `permission`-block key names / values
  in the current opencode schema so the §6.1 `--yolo` rewrite is correct.
- **`--model-name` support**: §3.2 pins the served id via
  `mlx_lm.server --model-name <basename>`. Confirm the mlx-lm version on the
  target exposes that flag; if not, drop the pin and fall back to reading the id
  from `/v1/models` into `MLX_MODEL_ID`.
- **`--model-opts` defaults**: keys pass straight through as `mlx_lm.server`
  option names, so nothing to design there — but document sensible KV/context
  values per model size in the README.
- **Prewarm** (optional usage tip, nothing to build): a user who wants the first
  session of the day to skip the model cold-load can run
  `opencode-mlx-sandbox mlx start` from a login item / launchd agent. Mention it
  in the README; the tool ships no prewarm feature of its own.
- **Model switching**: out of scope by design — one host server, one model. A
  request that does not match the running server errors out (§3.4); the user
  stops it and re-runs.