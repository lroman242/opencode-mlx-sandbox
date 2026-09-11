#!/usr/bin/env bash
# lib/mlx-server.sh - process supervisor over the host's existing mlx-lm install.
#
# Subcommands: ensure | start | stop | status | logs
#
# Runs on the macOS host: BSD userland, /bin/bash may be 3.2. Keep to 3.2
# constructs and POSIX tools. jq and curl are required;
# openssl (for tokens) and lsof (port check) ship with macOS.

set -u

if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -lt 3 ]; then
  echo "mlx-server.sh: needs bash >= 3.2" >&2
  exit 1
fi

CONFIG_DIR="${OMS_CONFIG_DIR:-$HOME/.config/opencode-mlx-sandbox}"
RUN_DIR="$CONFIG_DIR/run"
PID_FILE="$RUN_DIR/mlx.pid"
LOG_FILE="$RUN_DIR/mlx.log"
JSON_FILE="$RUN_DIR/mlx.json"

# ---------------------------------------------------------------------------
# .env loading (only sets vars that are not already set in the environment)
# ---------------------------------------------------------------------------
load_env() {
  local file="$CONFIG_DIR/.env"
  [ -f "$file" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      *=*) : ;;
      *) continue ;;
    esac
    key=${line%%=*}
    val=${line#*=}
    # trim surrounding whitespace
    key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    val=$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # strip trailing inline comment (only when preceded by whitespace)
    val=$(printf '%s' "$val" | sed 's/[[:space:]]\{1,\}#.*$//')
    # strip matching quotes
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    # leading ~/ -> $HOME/
    case "$val" in
      '~/'*) val="$HOME/${val#\~/}" ;;
    esac
    [ -n "$val" ] || continue
    if [ -z "$(eval "printf '%s' \"\${$key+x}\"")" ]; then
      eval "$key=\$val"
      export "$key"
    fi
  done < "$file"
}
load_env

MLX_VENV="${MLX_VENV:-$HOME/.venv-mlx}"
case "$MLX_VENV" in '~/'*) MLX_VENV="$HOME/${MLX_VENV#\~/}" ;; esac
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen2.5-Coder-7B-Instruct-4bit}"
MLX_HOST="${MLX_HOST:-127.0.0.1}"
MLX_PORT="${MLX_PORT:-8080}"
MLX_START_TIMEOUT="${MLX_START_TIMEOUT:-300}"
MLX_KEEP_ALIVE="${MLX_KEEP_ALIVE:-}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
die() { echo "mlx-server.sh: $*" >&2; exit 1; }
note() { echo "mlx-server.sh: $*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need curl
need jq

now_epoch() { date +%s; }

is_loopback() {
  case "$1" in
    127.*|::1|localhost|"") return 0 ;;
    *) return 1 ;;
  esac
}

dur_to_secs() {
  case "$1" in
    '') echo 0 ;;
    *s) echo "${1%s}" ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *) echo "$1" ;;
  esac
}

# Resolve --model to what mlx_lm.server should load.
resolve_model() {
  local spec="$1"
  case "$spec" in
    '~/'*) echo "$HOME/${spec#\~/}" ;;
    /*)    echo "$spec" ;;
    *)     echo "$spec" ;;   # org/name HF repo id, passed straight through
  esac
}

# mlx_lm.server has no --model-name flag and /v1/models does not report "the
# currently loaded model" (it lists every mlx-lm-compatible repo found in the
# whole HF cache, plus the resolved --model path if local - never a clean
# basename). What IS reliable: ModelProvider always aliases the literal string
# "default_model" -> whatever --model was set to (checked against the actual
# mlx-lm source). So the id opencode's config should use is always the fixed
# string "default_model" - no pinning/derivation needed.
MLX_MODEL_ID_FIXED="default_model"

# Build the extra-arg list from --mlx-opts (raw) and --model-opts (k=v,...).
# Emits one token per line; caller collects into an array.
build_opts() {
  local mlx_opts="$1" model_opts="$2"
  local IFS_SAVE="$IFS"
  # --model-opts: comma separated k=v / bare-k
  if [ -n "$model_opts" ]; then
    local part k v
    IFS=','
    for part in $model_opts; do
      IFS="$IFS_SAVE"
      [ -n "$part" ] || continue
      case "$part" in
        *=*)
          k=${part%%=*}; v=${part#*=}
          printf '%s\n' "--$k"
          printf '%s\n' "$v"
          ;;
        *)
          printf '%s\n' "--$part"
          ;;
      esac
      IFS=','
    done
    IFS="$IFS_SAVE"
  fi
  # --mlx-opts: verbatim, whitespace split
  if [ -n "$mlx_opts" ]; then
    local tok
    for tok in $mlx_opts; do
      printf '%s\n' "$tok"
    done
  fi
}

json_get() {
  # `// empty` treats jq-falsy values (false, 0, "") as missing, not just
  # null - that would turn managed:false or started_at:0 into "". Compare
  # against null explicitly instead.
  [ -f "$JSON_FILE" ] || { echo ""; return 0; }
  jq -r "($1) as \$v | if \$v == null then \"\" else \$v end" "$JSON_FILE" 2>/dev/null
}

pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

managed_pid() {
  local pid=""
  [ -f "$PID_FILE" ] && pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -z "$pid" ] && pid=$(json_get '.pid')
  echo "$pid"
}

# curl /v1/models. It lists every mlx-lm-compatible repo in the whole HF
# cache (not just the loaded one) plus the resolved --model path if local -
# never a single distinguished "current model". Echoes the raw `.data[].id`
# list, one per line (empty on failure).
probe_list() {
  local host="$1" port="$2" token="$3"
  local url="http://$host:$port/v1/models"
  if [ -n "$token" ]; then
    curl -fsS --max-time 5 -H "Authorization: Bearer $token" "$url" 2>/dev/null \
      | jq -r '.data[].id // empty' 2>/dev/null
  else
    curl -fsS --max-time 5 "$url" 2>/dev/null \
      | jq -r '.data[].id // empty' 2>/dev/null
  fi
}

# Is $4 present among the reported ids? echoes "yes"/"" (empty on unreachable
# or absent).
probe_has_model() {
  local host="$1" port="$2" token="$3" want="$4"
  local list; list=$(probe_list "$host" "$port" "$token")
  [ -z "$list" ] && return 1
  printf '%s\n' "$list" | grep -Fxq "$want" && echo yes
}

server_answering() {
  local host="$1" port="$2"
  curl -fsS --max-time 5 "http://$host:$port/v1/models" >/dev/null 2>&1
}

port_listener_pid() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | head -n1
}

activate_venv_or_die() {
  [ -f "$MLX_VENV/bin/activate" ] || \
    die "MLX virtualenv not found at '$MLX_VENV' (set MLX_VENV in $CONFIG_DIR/.env)"
  # shellcheck disable=SC1090
  ( . "$MLX_VENV/bin/activate" && command -v mlx_lm.server >/dev/null 2>&1 ) || \
    die "mlx_lm.server not found in venv '$MLX_VENV' (set MLX_VENV in $CONFIG_DIR/.env)"
}

write_json() {
  # write_json <model> <model_id> <opts> <host> <port> <token> <pid> \
  #            <started_at> <last_used> <keep_alive> <managed:true|false>
  mkdir -p "$RUN_DIR"
  jq -n \
    --arg model "$1" --arg model_id "$2" --arg opts "$3" \
    --arg host "$4" --arg port "$5" --arg token "$6" \
    --arg pid "$7" \
    --argjson started_at "${8:-0}" --argjson last_used "${9:-0}" \
    --arg keep_alive "${10}" --argjson managed "${11}" \
    '{model:$model, model_id:$model_id, opts:$opts, host:$host, port:$port,
      token:$token, pid:(if $pid=="" then null else ($pid|tonumber) end),
      started_at:$started_at, last_used:$last_used,
      keep_alive:$keep_alive, managed:$managed}' > "$JSON_FILE"
}

touch_last_used() {
  [ -f "$JSON_FILE" ] || return 0
  local tmp="$JSON_FILE.tmp"
  jq --argjson t "$(now_epoch)" '.last_used=$t' "$JSON_FILE" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$JSON_FILE"
}

# ---------------------------------------------------------------------------
# argument parsing for a subcommand (shared)
# ---------------------------------------------------------------------------
A_MODEL=""; A_HOST=""; A_PORT=""; A_MLX_OPTS=""; A_MODEL_OPTS=""
A_KEEP_ALIVE=""; A_NO_AUTH=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)        A_MODEL="$2"; shift 2 ;;
      --host)         A_HOST="$2"; shift 2 ;;
      --port)         A_PORT="$2"; shift 2 ;;
      --mlx-opts)     A_MLX_OPTS="$2"; shift 2 ;;
      --model-opts)   A_MODEL_OPTS="$2"; shift 2 ;;
      --mlx-keep-alive) A_KEEP_ALIVE="$2"; shift 2 ;;
      --mlx-no-auth)  A_NO_AUTH=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

# Populated by resolve_request
R_MODEL_SPEC=""; R_MODEL=""; R_MODEL_ID=""; R_OPTS=""
R_HOST=""; R_PORT=""; R_KEEP_ALIVE=""

resolve_request() {
  R_MODEL_SPEC="${A_MODEL:-$MLX_MODEL}"
  R_MODEL=$(resolve_model "$R_MODEL_SPEC")
  R_MODEL_ID="$MLX_MODEL_ID_FIXED"
  R_HOST="${A_HOST:-$MLX_HOST}"
  R_PORT="${A_PORT:-$MLX_PORT}"
  R_KEEP_ALIVE="${A_KEEP_ALIVE:-$MLX_KEEP_ALIVE}"
  local opts
  opts=$(build_opts "$A_MLX_OPTS" "$A_MODEL_OPTS" | tr '\n' ' ')
  R_OPTS=$(printf '%s' "$opts" | sed 's/[[:space:]]*$//')
}

# ---------------------------------------------------------------------------
# idle sweep
# ---------------------------------------------------------------------------
idle_sweep() {
  [ -f "$JSON_FILE" ] || return 0
  [ "$(json_get '.managed')" = "true" ] || return 0
  local ka; ka=$(json_get '.keep_alive')
  [ -n "$ka" ] || return 0
  local window; window=$(dur_to_secs "$ka")
  [ "$window" -gt 0 ] 2>/dev/null || return 0
  local last; last=$(json_get '.last_used')
  [ -n "$last" ] || return 0
  local age=$(( $(now_epoch) - last ))
  if [ "$age" -gt "$window" ]; then
    note "idle for ${age}s (> ${window}s keep-alive) - stopping managed server"
    do_stop
  fi
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
# Wait for /v1/models to be reachable AND list our resolved --model value
# (see probe_has_model - there is no single "current model" field to assert
# against, so presence-in-cache-scan is the correctness check).
health_wait() {
  local host="$1" port="$2" token="$3" want_model="$4"
  local deadline=$(( $(now_epoch) + MLX_START_TIMEOUT ))
  while [ "$(now_epoch)" -lt "$deadline" ]; do
    if [ "$(probe_has_model "$host" "$port" "$token" "$want_model")" = "yes" ]; then
      note "server healthy: $want_model  (opencode: mlx/$MLX_MODEL_ID_FIXED, http://$host:$port/v1)"
      return 0
    fi
    if server_answering "$host" "$port"; then
      note "server answering but '$want_model' not yet in /v1/models - waiting"
    fi
    sleep 2
  done
  note "----- last lines of $LOG_FILE -----"
  tail -n 20 "$LOG_FILE" >&2 2>/dev/null || true
  die "server did not report '$want_model' in /v1/models within ${MLX_START_TIMEOUT}s"
}

do_start() {
  resolve_request

  if ! is_loopback "$R_HOST"; then
    die "cannot start a server on non-loopback host '$R_HOST' (connect-only)"
  fi

  # already answering?
  if server_answering "$R_HOST" "$R_PORT"; then
    note "server already answering at $R_HOST:$R_PORT - checking match"
    check_match_or_die
    touch_last_used
    return 0
  fi

  # port held by something that is not an MLX server?
  local lp; lp=$(port_listener_pid "$R_PORT")
  if [ -n "$lp" ]; then
    die "port $R_PORT is held (pid $lp) but /v1/models there is not responding as an MLX server"
  fi

  activate_venv_or_die

  local token=""
  if [ "$A_NO_AUTH" -eq 0 ]; then
    token=$(openssl rand -hex 24)
  fi

  mkdir -p "$RUN_DIR"
  : > "$LOG_FILE"

  # assemble command. mlx_lm.server has no --model-name or --api-key flag
  # (verified against the mlx-lm source) - the token is still generated and
  # handed to the container as MLX_API_KEY (forward-compatible / sent as a
  # header the server currently just ignores), but it is never passed on the
  # command line and enforces nothing server-side today.
  set -- mlx_lm.server --model "$R_MODEL" --host "$R_HOST" --port "$R_PORT"
  if [ -n "$R_OPTS" ]; then
    local tok
    for tok in $R_OPTS; do set -- "$@" "$tok"; done
  fi

  note "starting: $*"
  ( . "$MLX_VENV/bin/activate" && exec "$@" ) >> "$LOG_FILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_FILE"

  local nowe; nowe=$(now_epoch)
  write_json "$R_MODEL" "$R_MODEL_ID" "$R_OPTS" "$R_HOST" "$R_PORT" "$token" \
    "$pid" "$nowe" "$nowe" "$R_KEEP_ALIVE" true

  # give the child a moment; detect immediate crash
  sleep 1
  if ! pid_alive "$pid"; then
    note "----- $LOG_FILE -----"
    tail -n 20 "$LOG_FILE" >&2 2>/dev/null || true
    die "server process exited immediately"
  fi

  health_wait "$R_HOST" "$R_PORT" "$token" "$R_MODEL"
}

# ---------------------------------------------------------------------------
# match check
# ---------------------------------------------------------------------------
check_match_or_die() {
  resolve_request
  local mpid; mpid=$(managed_pid)
  local managed_ok=0
  if [ "$(json_get '.managed')" = "true" ] && pid_alive "$mpid" \
     && [ "$(json_get '.host')" = "$R_HOST" ] && [ "$(json_get '.port')" = "$R_PORT" ]; then
    managed_ok=1
  fi

  if [ "$managed_ok" -eq 1 ]; then
    local rm_model rm_opts
    rm_model=$(json_get '.model'); rm_opts=$(json_get '.opts')
    if [ "$rm_model" != "$R_MODEL" ]; then
      die "running server model '$rm_model' != requested '$R_MODEL' - stop it (mlx stop) or match the request"
    fi
    if [ "$rm_opts" != "$R_OPTS" ]; then
      die "running server opts '[$rm_opts]' != requested '[$R_OPTS]' - stop it (mlx stop) or match the request"
    fi
    note "reusing managed server ($rm_model) at $R_HOST:$R_PORT"
    return 0
  fi

  # server we did not start: the only thing checkable is whether our
  # resolved --model value shows up in its /v1/models cache scan.
  local list; list=$(probe_list "$R_HOST" "$R_PORT" "")
  if [ -z "$list" ]; then
    note "server at $R_HOST:$R_PORT answered but /v1/models returned nothing - cannot verify model"
    return 0
  fi
  if ! printf '%s\n' "$list" | grep -Fxq "$R_MODEL"; then
    die "server at $R_HOST:$R_PORT does not report '$R_MODEL' in /v1/models (running vs requested mismatch)"
  fi
  note "connecting to external server ($R_MODEL) at $R_HOST:$R_PORT"
}

# ---------------------------------------------------------------------------
# ensure - the entry point the launcher calls
# ---------------------------------------------------------------------------
do_ensure() {
  resolve_request
  idle_sweep

  if server_answering "$R_HOST" "$R_PORT"; then
    check_match_or_die
    # record managed=false marker if we have no json for this endpoint
    if [ ! -f "$JSON_FILE" ] || [ "$(json_get '.host'):$(json_get '.port')" != "$R_HOST:$R_PORT" ]; then
      write_json "$R_MODEL" "$R_MODEL_ID" "$R_OPTS" "$R_HOST" "$R_PORT" "" "" \
        "0" "$(now_epoch)" "$R_KEEP_ALIVE" false
    else
      touch_last_used
    fi
    return 0
  fi

  if ! is_loopback "$R_HOST"; then
    die "nothing answering at $R_HOST:$R_PORT and host is not loopback - cannot start a remote server"
  fi

  do_start
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
do_stop() {
  if [ "$(json_get '.managed')" != "true" ]; then
    note "no managed server recorded - nothing to stop"
    return 0
  fi
  local pid; pid=$(managed_pid)
  if pid_alive "$pid"; then
    note "stopping server (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    local deadline=$(( $(now_epoch) + 10 ))
    while pid_alive "$pid" && [ "$(now_epoch)" -lt "$deadline" ]; do
      sleep 1
    done
    if pid_alive "$pid"; then
      note "still alive - SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  else
    note "recorded pid not running"
  fi
  rm -f "$PID_FILE" "$JSON_FILE"
  note "stopped; cleared $RUN_DIR"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
do_status() {
  idle_sweep
  if [ ! -f "$JSON_FILE" ]; then
    echo "no MLX server recorded (run: opencode-mlx-sandbox mlx start)"
    return 0
  fi
  local model model_id host port pid started keep managed token
  model=$(json_get '.model'); model_id=$(json_get '.model_id')
  host=$(json_get '.host'); port=$(json_get '.port')
  pid=$(json_get '.pid'); started=$(json_get '.started_at')
  keep=$(json_get '.keep_alive'); managed=$(json_get '.managed')
  token=$(json_get '.token')

  echo "model:        $model"
  echo "opencode id:  mlx/$MLX_MODEL_ID_FIXED   (fixed - mlx-lm aliases this to --model)"
  echo "host:port:    $host:$port"
  echo "managed:      $managed"
  if [ "$managed" = "true" ]; then
    if pid_alive "$pid"; then
      local up=$(( $(now_epoch) - started ))
      echo "pid:          $pid  (up ${up}s)"
    else
      echo "pid:          $pid  (NOT running)"
    fi
  fi
  echo "keep-alive:   ${keep:-<until mlx stop>}"

  if [ "$(probe_has_model "$host" "$port" "$token" "$model")" = "yes" ]; then
    echo "/v1/models:   OK -> '$model' present"
  else
    local list; list=$(probe_list "$host" "$port" "$token")
    if [ -n "$list" ]; then
      echo "/v1/models:   reachable but '$model' NOT in the list:"
      printf '%s\n' "$list" | sed 's/^/                /'
    else
      echo "/v1/models:   unreachable"
      echo "last log:     $(tail -n 1 "$LOG_FILE" 2>/dev/null)"
    fi
  fi
}

do_logs() {
  [ -f "$LOG_FILE" ] || die "no log at $LOG_FILE"
  if [ -t 1 ]; then
    exec tail -n 200 -f "$LOG_FILE"
  else
    tail -n 200 "$LOG_FILE"
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || die "usage: mlx-server.sh {ensure|start|stop|status|logs} [options]"
CMD="$1"; shift
case "$CMD" in
  ensure) parse_args "$@"; do_ensure ;;
  start)  parse_args "$@"; do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  logs)   do_logs ;;
  mark-used) touch_last_used ;;
  *) die "unknown subcommand: $CMD" ;;
esac
