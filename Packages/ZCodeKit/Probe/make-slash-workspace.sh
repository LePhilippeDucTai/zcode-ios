#!/bin/sh
# Throwaway project for the slash-command probe (zcode-probe composer, Probe/slash-read.json): two project skills, one
# sharing its name with a user-level skill (review-agent) to observe de-duplication. Also runs as
# `ssh <user>@<linux-host> 'sh -s DIR' < make-slash-workspace.sh`.
set -eu
dir=${1:?usage: make-slash-workspace.sh DIR}
case "$dir" in
  */.zcode-check/*) ;;
  *) echo "DIR must be under a .zcode-check directory: $dir" >&2; exit 2 ;;
esac
if [ -e "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
  echo "$dir exists and is not empty" >&2
  exit 1
fi
mkdir -p "$dir/.zcode/skills/zcode-ios-probe-skill" "$dir/.zcode/skills/review-agent"
cat > "$dir/.zcode/skills/zcode-ios-probe-skill/SKILL.md" <<'EOF'
---
name: zcode-ios-probe-skill
description: Skill jetable de zcode-probe (projet)
---
Réponds OK.
EOF
cat > "$dir/.zcode/skills/review-agent/SKILL.md" <<'EOF'
---
name: review-agent
description: Homonyme jetable d'une skill utilisateur (dédoublonnage)
---
Réponds OK.
EOF
echo "$dir"
