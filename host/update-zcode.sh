#!/bin/zsh
# Upgrades this host's ZCode web server to the given tag with no downtime during the build:
# the new version is built next to the running service, verified with `zcode-probe check` against
# a spare server (127.0.0.1, free port 3031–3039, never exposed to the tailnet), then `current` is
# switched and the service restarted. If the check or the post-switch verification fails, the old
# version stays in service (the link is rolled back).
#
#   host/update-zcode.sh <tag> [--workspace PATH] [--keep N] [--token-file FILE] [--rebuild] [--skip-check]
#
# - <tag>        : ZCode git tag (e.g. v3.15.1); build skipped if already present in versions/
# - --rebuild    : rebuild even if this version is already in service (staging fix); output goes to
#                  versions/<version>+r<timestamp>, the old directory stays as rollback material
# - --skip-check : skip the contract test (the only GLM prompt); the spare server's reported version,
#                  the bundled skill check and the post-switch verification still run
# - --workspace  : workspace for the spare server and the check (default: $ZCODE_WORKSPACE, else $HOME)
# - --keep N     : old versions kept in addition to the previous one, as rollback material (default 0)
# - --token-file : server token (default ~/.config/zcode-web/token)
#
# macOS only (the check needs Swift and this repository's Packages/ZCodeKit); for a Linux host,
# see host/linux/README.md. Cost: one GLM prompt per check.
set -euo pipefail

# Same as host/install-zcode.sh: a ZCode session's environment must reach neither the build nor
# the spare server (another version's builtin config, the server token…).
unset ZCODE_AGENT_SERVER_ARGS_JSON ZCODE_AGENT_SERVER_COMMAND ZCODE_SERVER_HOST \
  ZCODE_SERVER_WORKSPACE ZCODE_WEB_STATIC_ROOT ZCODE_SERVER_AUTH_TOKEN ZCODE_RUNTIME_ENV \
  ZCODE_BASE_URL ZCODE_GEN_UI_OUTPUT_ROOT ZCODE_BUILTIN_PROVIDER_CONFIG_FILE \
  ZCODE_PERSONAL_PROVIDER_CONFIG_FILE

LABEL="local.zcode-web"
PORT="${ZCODE_PORT:-3030}"

usage() { print -u2 "Usage: update-zcode.sh <tag> [--workspace PATH] [--keep N] [--token-file FILE] [--rebuild] [--skip-check]"; }
TAG="${1:-}"; [[ -n "$TAG" ]] || { usage; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 "Invalid tag: ${TAG} (expected form: v3.15.1)"; exit 2; }
shift

WORKSPACE="${ZCODE_WORKSPACE:-$HOME}"
KEEP=0
TOKEN_FILE="$HOME/.config/zcode-web/token"
REBUILD=0
SKIP_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace) WORKSPACE="${2:?"$1 requires a value"}"; shift 2 ;;
    --keep) KEEP="${2:?"$1 requires a value"}"; shift 2 ;;
    --token-file) TOKEN_FILE="${2:?"$1 requires a value"}"; shift 2 ;;
    --rebuild) REBUILD=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    *) print -u2 "Unknown option: $1"; usage; exit 2 ;;
  esac
done
[[ -d "$WORKSPACE" ]] || { print -u2 "Workspace not found: $WORKSPACE"; exit 2; }
[[ "$KEEP" =~ ^[0-9]+$ ]] || { print -u2 "--keep requires an integer: $KEEP"; exit 2; }

ROOT="${0:A:h}/.."
BASE="$HOME/.local/share/zcode-web"
CURRENT="$BASE/current"
[[ -x "$BASE/bin/run-zcode-web.sh" ]] || { print -u2 "No zcode-web runtime here; run host/install-zcode.sh <tag> --activate first."; exit 2; }
OLD_TARGET="$(readlink "$CURRENT" 2>/dev/null || true)"
[[ -n "$OLD_TARGET" ]] || { print -u2 "current link not found ($CURRENT); run host/install-zcode.sh <tag> --activate first."; exit 2; }
# A rebuilt directory (--rebuild) is named <version>+r<timestamp>: the server reports <version>.
OLD_VERSION="${${OLD_TARGET:t}%%+*}"
NEW_VERSION="${TAG#v}"
NEW_DIR="$BASE/versions/$NEW_VERSION"

if [[ "$(uname)" == "Darwin" ]]; then
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 \
    || { print -u2 "LaunchAgent $LABEL not found; run host/macos/install-service.sh first."; exit 2; }
  restart_service() { launchctl kickstart -k "gui/$(id -u)/$LABEL"; }
else
  systemctl --user is-active --quiet zcode-web \
    || { print -u2 "zcode-web unit not found; run host/linux/install-service.sh first."; exit 2; }
  restart_service() { systemctl --user restart zcode-web; }
fi

probe_info() {  # probe_info URL → server version (empty if unreachable)
  "$PROBE" info --url "$1" --token-file "$TOKEN_FILE" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true
}

wait_version() {  # wait_version URL EXPECTED_VERSION → 0 once the server reports that version
  local url="$1" expected="$2" i v
  for i in {1..90}; do
    v="$(probe_info "$url")"
    [[ "$v" == "$expected" ]] && return 0
    sleep 1
  done
  return 1
}

if [[ "$NEW_VERSION" == "$OLD_VERSION" ]] && (( ! REBUILD )); then
  print "ZCode $OLD_VERSION already in service; nothing to do."
  [[ "$(cat "$ROOT/host/installed-version.txt" 2>/dev/null || true)" == "$TAG" ]] \
    || print -r -- "$TAG" > "$ROOT/host/installed-version.txt"
  exit 0
fi

# 1. Build the new version next to the running service (no downtime for the app).
if (( REBUILD )); then
  # Never into the live directory: install-zcode.sh empties its output before filling it.
  NEW_DIR="$BASE/versions/$NEW_VERSION+r$(date +%Y%m%d%H%M%S)"
  print "Rebuilding ZCode $TAG into ${NEW_DIR:t} (the service keeps running on ${OLD_TARGET:t})…"
  ZCODE_INSTALL_DIR="$NEW_DIR" "$ROOT/host/install-zcode.sh" "$TAG"
elif [[ -d "$NEW_DIR" ]]; then
  print "ZCode $NEW_VERSION already built (build skipped)."
else
  print "Building ZCode $TAG (the service keeps running on $OLD_VERSION)…"
  "$ROOT/host/install-zcode.sh" "$TAG"
  if [[ ! -d "$NEW_DIR" ]]; then
    # The directory normally follows the package.json version, not the tag.
    SRC="${ZCODE_SRC:-$HOME/src/ZCode}"
    NEW_DIR="$BASE/versions/$(cd "$SRC" && mise exec -- node -p 'require("./package.json").version')"
  fi
fi
[[ -d "$NEW_DIR" ]] || { print -u2 "New version directory not found: $NEW_DIR"; exit 1; }

# Bundled skill `dynamic-workflows` (required by /workflow) visible from the runtime, without a prompt.
# Node: ZCODE_NODE, else the newest mise-installed Node 24, else `node` from PATH (as run-zcode-web.sh).
NODE="${ZCODE_NODE:-}"
if [[ -z "$NODE" ]]; then
  mise_nodes=($HOME/.local/share/mise/installs/node/24.<->.<->/bin/node(N*n))
  if (( ${#mise_nodes} )); then
    NODE="${mise_nodes[-1]}"
  else
    NODE="$(command -v node || true)"
  fi
fi
[[ -n "$NODE" && -x "$NODE" ]] || { print -u2 "Node not found (set ZCODE_NODE, or install Node 24 with mise): ${NODE:-none}"; exit 2; }
SKILL_CWD="$(mktemp -d "${TMPDIR:-/tmp}/zcode-skills.XXXXXX")"
if ! (cd "$SKILL_CWD" && "$NODE" "$NEW_DIR/agent/zcode.cjs" skills inspect dynamic-workflows >/dev/null 2>&1); then
  rm -rf "$SKILL_CWD"
  print -u2 "Bundled skill dynamic-workflows missing from $NEW_DIR: ${OLD_TARGET:t} stays in service."
  exit 1
fi
rm -rf "$SKILL_CWD"
print "Bundled skill dynamic-workflows present."

# 2. Build the probe once, reused for every call.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$DEVELOPER_DIR" ]] || { print -u2 "Xcode not found ($DEVELOPER_DIR), required for zcode-probe."; exit 2; }
swift build --package-path "$ROOT/Packages/ZCodeKit" >/dev/null
PROBE="$ROOT/Packages/ZCodeKit/.build/debug/zcode-probe"

# 3. Spare server on the new version. It shares ~/.zcode and the workspace with the running
#    service (as a desktop ZCode would): the check creates then deletes its own session, without
#    touching the others.
SPARE_PORT=""
for p in {3031..3039}; do
  if ! lsof -ti "tcp:$p" >/dev/null 2>&1; then SPARE_PORT="$p"; break; fi
done
[[ -n "$SPARE_PORT" ]] || { print -u2 "No free port between 3031 and 3039."; exit 1; }
SPARE_LOG="$(mktemp "${TMPDIR:-/tmp}/zcode-update.XXXXXX")"
SPARE_PID=""
stop_spare() {
  [[ -n "$SPARE_PID" ]] && kill "$SPARE_PID" 2>/dev/null || true
  lsof -ti "tcp:$SPARE_PORT" | xargs kill 2>/dev/null || true
  [[ -n "$SPARE_PID" ]] && wait "$SPARE_PID" 2>/dev/null || true
  SPARE_PID=""
}
print "Spare server on 127.0.0.1:$SPARE_PORT (ZCode $NEW_VERSION)…"
ZCODE_NODE="$NODE" ZCODE_RUNTIME="$NEW_DIR" ZCODE_PORT="$SPARE_PORT" ZCODE_WORKSPACE="$WORKSPACE" ZCODE_TOKEN_FILE="$TOKEN_FILE" \
  zsh "$ROOT/host/run-zcode-web.sh" >"$SPARE_LOG" 2>&1 &
SPARE_PID=$!
trap stop_spare EXIT

if ! wait_version "http://127.0.0.1:$SPARE_PORT" "$NEW_VERSION"; then
  print -u2 "Spare server does not report version $NEW_VERSION (log: $SPARE_LOG):"
  tail -5 "$SPARE_LOG" >&2 || true
  exit 1
fi
print "Spare server ready (ZCode $NEW_VERSION)."

# 4. End-to-end contract (one GLM prompt) BEFORE any switch.
if (( SKIP_CHECK )); then
  print "Contract test skipped (--skip-check)."
else
  print "Contract test (zcode-probe check)…"
  if ! "$PROBE" check --url "http://127.0.0.1:$SPARE_PORT" --token-file "$TOKEN_FILE" --workspace "$WORKSPACE"; then
    print -u2 "Check failed: ZCode $OLD_VERSION stays in service (server log: $SPARE_LOG)."
    exit 1
  fi
fi
stop_spare
trap - EXIT

# 5. Switch + restart; roll back if the live service does not report the new version.
print "Switching to ZCode $NEW_VERSION and restarting the service…"
ln -sfn "$NEW_DIR" "$CURRENT"
restart_service
if ! wait_version "http://127.0.0.1:$PORT" "$NEW_VERSION"; then
  print -u2 "Live service not on $NEW_VERSION after restart — rolling back to ${OLD_TARGET:t}."
  ln -sfn "$OLD_TARGET" "$CURRENT"
  restart_service
  wait_version "http://127.0.0.1:$PORT" "$OLD_VERSION" || print -u2 "The service does not report $OLD_VERSION either: check its logs."
  exit 1
fi

# 6. Cleanup: the active and the previous (rollback) versions are always kept; --keep adds more.
kept=0
for d in "$BASE/versions"/*(N/Om); do
  name="${d:t}"
  [[ "$name" == "${NEW_DIR:t}" || "$name" == "${OLD_TARGET:t}" ]] && continue
  if (( kept < KEEP )); then kept=$((kept + 1)); continue; fi  # (( kept++ )) evaluates to 0 on the first pass: set -e would exit
  print "Removing old version $name…"
  rm -rf "$d"
done

# 7. Installed version, read by the GitHub release watch (its issue closes on the workflow's next run).
print -r -- "$TAG" > "$ROOT/host/installed-version.txt"
print "ZCode ${NEW_DIR:t} in service (previous: ${OLD_TARGET:t})."
print "Push the host/installed-version.txt bump to close the release-watch issue:"
print "  git -C $ROOT add host/installed-version.txt && git -C $ROOT commit -m 'ZCode $TAG' && git -C $ROOT push"
