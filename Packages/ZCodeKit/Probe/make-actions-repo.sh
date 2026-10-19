#!/bin/sh
# Throwaway Git repository with a local bare remote, used to record the `git-actions` fixtures (real mutations,
# push without network or credentials):
#   Probe/make-actions-repo.sh
#   REPO=/private/tmp/zcode-actions-repo swift run zcode-probe run Probe/git-actions.json --record /tmp/zcode-actions-rec
# then clean up (see Tests/Fixtures/README.md) and delete both directories.
set -eu
REPO=/private/tmp/zcode-actions-repo
REMOTE=/private/tmp/zcode-actions-remote.git
rm -rf "$REPO" "$REMOTE"
git init -q --bare "$REMOTE"
mkdir -p "$REPO/src"
cd "$REPO"
git init -q -b main
git config user.email fixture@example.com
git config user.name Fixture
printf '# Actions\n\nLigne 1\n' > README.md
printf 'func salut() {\n    print("bonjour")\n}\n' > src/app.swift
printf 'a\n' > notes.txt
git add -A
git commit -qm init
git switch -q -c autre
printf '# Autre\n' > README.md
git commit -qam autre
git switch -q main
git remote add origin "$REMOTE"
printf '# Actions\n\nLigne 1\nLigne 2\n' > README.md
printf 'func salut() {\n    print("bonjour, monde")\n}\n' > src/app.swift
git add src/app.swift
printf 'a\nb\n' > notes.txt
printf 'nouveau\n' > new.txt
git status --short
