#!/bin/sh
# Throwaway marketplace used to record the `plugins-lifecycle` fixtures: one `zcode-ios-probe` plugin with one skill,
# no command, no hook, no MCP server, no script. Two options: `label` (non-sensitive, default `sonde`) and
# `codeFactice` (sensitive; the name avoids `zcode-probe`'s `…token` / `…secret` redaction).
#   Probe/make-plugin-marketplace.sh <workspace>/.zcode-check/marketplace
#   ssh <user>@<linux-host> 'sh -s <workspace>/.zcode-check/marketplace' < Probe/make-plugin-marketplace.sh
# Refuses an existing non-empty directory. Prints the absolute path of the created directory.
set -eu
if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "Usage: make-plugin-marketplace.sh DIR" >&2
  exit 2
fi
DIR=$1
if [ -d "$DIR" ] && [ -n "$(ls -A "$DIR")" ]; then
  echo "Refusing: $DIR exists and is not empty" >&2
  exit 1
fi
if [ -e "$DIR" ] && [ ! -d "$DIR" ]; then
  echo "Refusing: $DIR exists and is not a directory" >&2
  exit 1
fi
PLUGIN="$DIR/plugins/zcode-ios-probe"
mkdir -p "$DIR/.claude-plugin" "$PLUGIN/.zcode-plugin" "$PLUGIN/skills/zcode-ios-probe"

cat > "$DIR/.claude-plugin/marketplace.json" <<'EOF'
{"name":"zcode-ios-probe-market","description":"Marketplace jetable de zcode-probe","plugins":[{"name":"zcode-ios-probe","version":"1.0.0","displayName":"Sonde iOS","description":"Plugin jetable : une skill, aucune commande.","category":"utilities","author":{"name":"zcode_ios"},"source":"./plugins/zcode-ios-probe"}]}
EOF

cat > "$PLUGIN/.zcode-plugin/plugin.json" <<'EOF'
{"name":"zcode-ios-probe","version":"1.0.0","description":"Plugin jetable : une skill, aucune commande.","skills":"skills","userConfig":{"label":{"type":"string","title":"Libellé","default":"sonde","description":"Option non sensible"},"codeFactice":{"type":"string","title":"Code factice","sensitive":true,"description":"Option sensible (valeur factice)"}}}
EOF

cat > "$PLUGIN/skills/zcode-ios-probe/SKILL.md" <<'EOF'
---
name: zcode-ios-probe
description: Skill jetable de zcode-probe
---

Skill jetable écrite par zcode-probe : ne fait rien.
EOF

cd "$DIR" && pwd
