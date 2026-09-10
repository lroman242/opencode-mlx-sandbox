# opencode-mlx-sandbox

Run the [opencode](https://opencode.ai) coding agent inside a disposable,
per-folder Docker container, driven by a local **MLX** model served on your Mac.
Fully local: the model runs on the host under Apple's MLX runtime, the agent runs
sandboxed in a container that can only see the one project folder you point it at
and can never write back to your global opencode config.

See [`spec.md`](spec.md) for the full design.

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
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKey": "{env:MLX_API_KEY}"
      }
    }
  },
  "model": "mlx/<model-basename>"
}
```

`<model-basename>` is your `--model` value with any `org/` prefix or path
stripped (e.g. `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit` →
`Qwen2.5-Coder-7B-Instruct-4bit`). `mlx status` prints the exact string.
`baseURL`'s port must match `--port` / `MLX_PORT`. Drop `apiKey` if you pass
`--mlx-no-auth`.

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