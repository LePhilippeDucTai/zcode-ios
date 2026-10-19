#!/bin/zsh
# Builds a ZCode release and installs its `zcode --web` runtime.
#
#   host/install-zcode.sh <tag> [--activate]
#
# - source checkout   : ~/src/ZCode (reused across versions; override with ZCODE_SRC)
# - runtime           : ~/.local/share/zcode-web/versions/<version>
# - --activate        : points ~/.local/share/zcode-web/current at this version
# - ZCODE_INSTALL_DIR : output directory instead of versions/<version> (rebuild of a version
#                       already in service without overwriting the live directory: update-zcode.sh --rebuild)
#
# Requires mise (`brew install mise`; on SteamOS: host/linux/bootstrap-steamos.sh). Node/pnpm are pinned by
# ZCode's mise.toml. On a host without a compiler (e.g. SteamOS), `pnpm install` fails on node-pty / cpu-features
# (node-gyp, "not found: make"); rerun inside an Arch distrobox container (same $HOME, hence same output):
#   distrobox create --name zcode-build --image docker.io/library/archlinux:latest --yes
#   distrobox enter zcode-build -- sudo pacman -Sy --needed --noconfirm base-devel git zsh curl python
#   distrobox enter zcode-build -- env PATH=$HOME/.local/bin:$PATH zsh ~/zcode-host/install-zcode.sh <tag> --activate
set -euo pipefail

# A ZCode session's environment (server agent, desktop app…) leaks into the build if the script
# is started from one of them: ZCODE_BUILTIN_PROVIDER_CONFIG_FILE would point at another version's
# staged config (incompatible schema, seen when building an older tag) and the server token has
# no business in a build. Start from the checked-out repository's config.
unset ZCODE_AGENT_SERVER_ARGS_JSON ZCODE_AGENT_SERVER_COMMAND ZCODE_SERVER_HOST \
  ZCODE_SERVER_WORKSPACE ZCODE_WEB_STATIC_ROOT ZCODE_SERVER_AUTH_TOKEN ZCODE_RUNTIME_ENV \
  ZCODE_BASE_URL ZCODE_GEN_UI_OUTPUT_ROOT ZCODE_BUILTIN_PROVIDER_CONFIG_FILE \
  ZCODE_PERSONAL_PROVIDER_CONFIG_FILE

TAG="${1:?Usage: install-zcode.sh <tag> [--activate]}"
ACTIVATE="${2:-}"
SRC="${ZCODE_SRC:-$HOME/src/ZCode}"
BASE="$HOME/.local/share/zcode-web"
HERE="${0:A:h}"

# `http.version=HTTP/1.1`: on some networks HTTP/2 breaks the transfer
# ("fetch-pack: unexpected disconnect while reading sideband packet").
if [[ ! -d "$SRC/.git" ]]; then
  git -c http.version=HTTP/1.1 clone --depth 1 --branch "$TAG" https://github.com/zai-org/ZCode.git "$SRC"
else
  git -c http.version=HTTP/1.1 -C "$SRC" fetch --depth 1 origin "refs/tags/${TAG}:refs/tags/${TAG}"
  git -C "$SRC" checkout --force "$TAG"
fi

cd "$SRC"
mise trust >/dev/null
mise install
# Electron and git hooks are not needed for web mode.
export ELECTRON_SKIP_BINARY_DOWNLOAD=1 HUSKY=0
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm --filter "@zcode/cli..." build
mise exec -- pnpm --filter @zcode/server build
mise exec -- pnpm --filter @zcode/web build

VERSION="$(mise exec -- node -p 'require("./package.json").version')"
DEST="${ZCODE_INSTALL_DIR:-$BASE/versions/$VERSION}"
mise exec -- node "$HERE/stage-zcode.mjs" "$SRC" "$DEST"

mkdir -p "$BASE/bin"
cp "$HERE/run-zcode-web.sh" "$BASE/bin/run-zcode-web.sh"
chmod 755 "$BASE/bin/run-zcode-web.sh"

if [[ "$ACTIVATE" == "--activate" ]]; then
  ln -sfn "$DEST" "$BASE/current"
  print "ZCode $VERSION activated."
else
  print "ZCode $VERSION installed (not activated)."
fi
