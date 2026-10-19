#!/bin/zsh
# Installs (or reinstalls) the ZCode web server's systemd --user unit, then exposes it to the tailnet.
# Everything lives in $HOME, nothing outside it is modified (no sudo; works on SteamOS's immutable root).
# ZCODE_WORKSPACE, if set at install time, becomes the server's default workspace (default: $HOME).
set -euo pipefail

HERE="${0:A:h}"
UNIT="zcode-web"
UNIT_FILE="$HOME/.config/systemd/user/$UNIT.service"
BASE="$HOME/.local/share/zcode-web"
STATE="$HOME/.local/state/zcode-web"
TOKEN_FILE="$HOME/.config/zcode-web/token"
WORKSPACE="${ZCODE_WORKSPACE:-$HOME}"
TS_BIN="${TS_BIN:-/opt/tailscale/tailscale}"
[[ -x "$TS_BIN" ]] || TS_BIN="$(command -v tailscale)"

# Shared token: generated once only (regenerating it revokes the iOS app's access).
if [[ ! -f "$TOKEN_FILE" ]]; then
  mkdir -p "${TOKEN_FILE:h}" && chmod 700 "${TOKEN_FILE:h}"
  if command -v openssl >/dev/null 2>&1; then
    (umask 077; openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > "$TOKEN_FILE")
  else
    (umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' > "$TOKEN_FILE")
  fi
fi

mkdir -p "$BASE/bin" "$STATE" "${UNIT_FILE:h}"
cp "$HERE/../run-zcode-web.sh" "$BASE/bin/run-zcode-web.sh"
chmod 755 "$BASE/bin/run-zcode-web.sh"
sed -e "s#__WORKSPACE__#$WORKSPACE#g" -e "s#__HOME__#$HOME#g" "$HERE/$UNIT.service" > "$UNIT_FILE"

systemctl --user daemon-reload
if systemctl --user is-active --quiet "$UNIT"; then
  systemctl --user restart "$UNIT"
else
  systemctl --user enable --now "$UNIT"
fi

# HTTPS at the tailnet root only (never `reset`, never `funnel`):
# `--set-path` adds the route without touching existing ones.
"$TS_BIN" serve --bg --set-path / http://127.0.0.1:3030
print "Service $UNIT running; tailnet:"
"$TS_BIN" serve status 2>/dev/null | head -8
