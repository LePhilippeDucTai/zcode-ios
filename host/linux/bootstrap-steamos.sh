#!/bin/zsh
# Prepares $HOME for building ZCode on SteamOS (immutable root: nothing outside $HOME).
# Installs mise (official installer, prebuilt binary) then prints the state of the tools.
set -euo pipefail

if [[ ! -x "$HOME/.local/bin/mise" ]]; then
  curl -fsSL https://mise.run | sh
else
  print "mise already present: $HOME/.local/bin/mise"
fi

print -- "--- mise     : $($HOME/.local/bin/mise --version)"
print -- "--- git      : $(git --version)"
print -- "--- zsh      : $(zsh --version)"
print -- "--- python3  : $(python3 --version 2>&1)"
print -- "--- steamos-readonly : $(steamos-readonly status 2>/dev/null || print 'unknown')"
print -- "--- Linger   : $(loginctl show-user "$USER" -p Linger 2>/dev/null || print 'unknown')"
