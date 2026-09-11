# opencode-mlx-sandbox

[![platform: macOS · Apple Silicon](https://img.shields.io/badge/platform-macOS%20%C2%B7%20Apple%20Silicon-black?logo=apple)](https://support.apple.com/en-us/116943)
[![runtime: Docker Desktop](https://img.shields.io/badge/runtime-Docker%20Desktop-2496ED?logo=docker&logoColor=white)](https://www.docker.com/products/docker-desktop/)
[![model: MLX (local)](https://img.shields.io/badge/model-MLX%20local-orange)](https://github.com/ml-explore/mlx-lm)
[![agent: opencode](https://img.shields.io/badge/agent-opencode-000)](https://opencode.ai)
[![shell: bash 3.2+](https://img.shields.io/badge/shell-bash%203.2%2B-4EAA25?logo=gnubash&logoColor=white)](#)

Run the [opencode](https://opencode.ai) coding agent inside a disposable,
per-folder Docker container, driven by a local **MLX** model served on your Mac.
Fully local: the model runs on the host under Apple's MLX runtime, the agent runs
sandboxed in a container that can only see the one project folder you point it at
and can never write back to your global opencode config.

## Requirements

- macOS on Apple Silicon with Docker Desktop
- `jq` on `PATH` (`brew install jq`)
- MLX + `mlx-lm` installed in a host virtualenv at `~/.venv-mlx`
  (override with `MLX_VENV` in `.env`)
- An MLX provider block in your `~/.config/opencode` (see below)

## Install

```bash
./install.sh
```

Copies build assets to `~/.config/opencode-mlx-sandbox/`, stages your
`~/.config/opencode`, installs `~/.local/bin/opencode-mlx-sandbox`, and builds
the image. Re-run any time to upgrade; `opencode-mlx-sandbox rebuild` re-stages
config + rebuilds only.

## Your opencode provider config

The sandbox never writes your provider/model selection — add it to
`~/.config/opencode/opencode.json` yourself:

```jsonc
{
  "provider": {
    "mlx": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      }
    }
  },
  "model": "mlx/default_model"
}
```

`mlx/default_model` is always the right id, regardless of which model you
pass via `--model` — `mlx_lm.server` has no `--model-name` flag and its
`/v1/models` endpoint doesn't report a single "current model" (it lists every
mlx-lm-compatible repo in your HF cache), but it does always alias the
literal string `default_model` to whatever `--model` it was started with, so
this never needs to change per model. `baseURL`'s port must match `--port` /
`MLX_PORT`.

`mlx_lm.server` has no server-side auth today, so there's nothing for
`apiKey` / `--mlx-no-auth` to protect — the token this tool generates is
forwarded to the container as `MLX_API_KEY` only for forward-compatibility
and isn't currently enforced by the server. Don't rely on it for security;
the MLX server is only reachable from your own container in the first place
(loopback + Docker's `host.docker.internal`).

## Use

```bash
cd ~/Projects/anything
opencode-mlx-sandbox                       # interactive opencode, default model
opencode-mlx-sandbox --model mlx-community/Qwen2.5-Coder-32B-Instruct-4bit
opencode-mlx-sandbox --model ~/models/my-4bit-mlx --yolo
opencode-mlx-sandbox run -- "add tests for the parser"
opencode-mlx-sandbox shell                 # bash in the container
opencode-mlx-sandbox mlx status
opencode-mlx-sandbox mlx stop
```

Run `opencode-mlx-sandbox --help` for the full command + option list.

### Subcommands

```
opencode-mlx-sandbox [PATH] [OPTIONS] [-- <opencode args>]
opencode-mlx-sandbox <SUBCOMMAND> [PATH] [OPTIONS]
```

`PATH` is positional, defaults to `.`, and is mounted at `/workspace`.

| Subcommand | What it does |
|---|---|
| _(none)_ | Ensure the image + host MLX server, then start an interactive `opencode` session for `PATH`. |
| `run` | Non-interactive: `opencode run "<prompt>"`. The prompt goes after `--`, e.g. `run -- "add tests"`. |
| `rebuild` | Re-stage `~/.config/opencode` and rebuild the image, then exit. |
| `build` | Build the image if it is missing, then exit (no-op if present). |
| `shell` | Start `bash` in the container instead of `opencode` (args after `--` are passed to `bash`). |
| `mlx start` | Start / ensure the host MLX server for `--model`, then exit. |
| `mlx stop` | Stop the host MLX server — only if this tool started it (`managed`). |
| `mlx status` | Print model, `mlx/default_model` (the fixed opencode id), host, port, PID, uptime, keep-alive, `managed` flag, and the live `/v1/models` probe. |
| `mlx logs` | Tail `~/.config/opencode-mlx-sandbox/run/mlx.log`. |
| `models` | List MLX models found in the local HuggingFace cache. |
| `stop` | Remove the container for `PATH` (session volume is kept). |
| `versions` | Print `opencode` + toolchain versions from the image. |
| `ps` | List `oms-` containers. |
| `rm` | Force-remove all `oms-` containers. |
| `volume ls` | List every per-project session volume, by path label. |
| `volume rm` | Remove every per-project session volume. |
| `rmi` | Remove the `opencode-mlx-sandbox:latest` image. |

Everything after `--` is passed straight to `opencode` (or to `bash` with `shell`).

### Prewarm (optional)

To skip the model cold-load on the first session of the day, run
`opencode-mlx-sandbox mlx start` from a login item or launchd agent.

## Model options

`--model-opts` keys are `mlx_lm.server`'s own long-option names:

```bash
opencode-mlx-sandbox --model-opts max-kv-size=8192,temp=0.7
opencode-mlx-sandbox --mlx-opts "--max-tokens 4096"
```

Larger models want a larger `max-kv-size` / context; tune per model size.

## Notes

- One host MLX server, one model. A request that doesn't match the running
  server errors out — stop it (`mlx stop`) and re-run, or match the request.
- Each project folder gets a Docker volume `oms-<hash>` for opencode session
  history, so `opencode` resume works between runs. `--fresh` wipes it,
  `--no-persist` skips it.
- Remote / non-Apple MLX endpoint: `--host <addr> --port <n>` (connect-only,
  never starts a server; your config must name that same host).

## License

[MIT](LICENSE)
