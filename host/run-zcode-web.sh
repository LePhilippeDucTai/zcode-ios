#!/bin/zsh
# Starts the local `zcode --web` server (127.0.0.1); exposed to the tailnet by `tailscale serve`.
# Used by the macOS LaunchAgent (local.zcode-web) and the Linux systemd user unit (zcode-web).
#
# The token is read from a file (mode 600) and redacted from the logs: the ZCode launcher
# prints URLs with `?token=…` on stdout.
#
# Environment overrides: ZCODE_NODE, ZCODE_RUNTIME, ZCODE_TOKEN_FILE, ZCODE_PORT,
# ZCODE_WORKSPACE (default: $HOME).
set -euo pipefail

# Node: ZCODE_NODE, else the newest mise-installed Node 24, else `node` from PATH.
NODE="${ZCODE_NODE:-}"
if [[ -z "$NODE" ]]; then
  mise_nodes=($HOME/.local/share/mise/installs/node/24.<->.<->/bin/node(N*n))
  if (( ${#mise_nodes} )); then
    NODE="${mise_nodes[-1]}"
  else
    NODE="$(command -v node || true)"
  fi
fi
RUNTIME="${ZCODE_RUNTIME:-$HOME/.local/share/zcode-web/current}"
TOKEN_FILE="${ZCODE_TOKEN_FILE:-$HOME/.config/zcode-web/token}"
PORT="${ZCODE_PORT:-3030}"
WORKSPACE="${ZCODE_WORKSPACE:-$HOME}"

[[ -n "$NODE" && -x "$NODE" ]] || { print -u2 "Node not found (set ZCODE_NODE, or install Node 24 with mise): ${NODE:-none}"; exit 1; }
[[ -r "$TOKEN_FILE" ]] || { print -u2 "Token not found: $TOKEN_FILE"; exit 1; }

# Keep the host awake: on macOS `caffeinate -s` (while on AC power);
# on Linux, `systemd-inhibit` blocks sleep and idle while the server runs.
keep_awake=()
if [[ "$(uname)" == "Darwin" ]]; then
  keep_awake=(/usr/bin/caffeinate -s)
elif command -v systemd-inhibit >/dev/null 2>&1; then
  keep_awake=(systemd-inhibit --what=sleep:idle --who=zcode-web --why="ZCode web server" --mode=block)
fi

"${keep_awake[@]}" "$NODE" "$RUNTIME/bin/zcode.mjs" --web \
  --host 127.0.0.1 --port "$PORT" --token "$(<"$TOKEN_FILE")" \
  --workspace "$WORKSPACE" --no-open 2>&1 \
  | sed -u -E 's/token=[^&[:space:]]+/token=<REDACTED>/g'
