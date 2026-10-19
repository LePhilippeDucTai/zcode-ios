#!/bin/zsh
# Installs (or reinstalls) the ZCode web server LaunchAgent (local.zcode-web), then exposes it to the tailnet.
# ZCODE_WORKSPACE, if set at install time, becomes the server's default workspace (default: $HOME).
set -euo pipefail

HERE="${0:A:h}"
LABEL="local.zcode-web"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BASE="$HOME/.local/share/zcode-web"
TOKEN_FILE="$HOME/.config/zcode-web/token"
WORKSPACE="${ZCODE_WORKSPACE:-$HOME}"

# Shared token: generated once only (regenerating it revokes the iOS app's access).
if [[ ! -f "$TOKEN_FILE" ]]; then
  mkdir -p "${TOKEN_FILE:h}" && chmod 700 "${TOKEN_FILE:h}"
  (umask 077; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > "$TOKEN_FILE")
fi

mkdir -p "$BASE/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$HERE/../run-zcode-web.sh" "$BASE/bin/run-zcode-web.sh"
chmod 755 "$BASE/bin/run-zcode-web.sh"
sed -e "s#__WORKSPACE__#$WORKSPACE#g" -e "s#__HOME__#$HOME#g" "$HERE/$LABEL.plist" > "$PLIST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

# HTTPS on the tailnet only (never `funnel`).
tailscale serve --bg 3030 >/dev/null
print "Service $LABEL running; tailnet: $(tailscale serve status 2>/dev/null | head -1)"
