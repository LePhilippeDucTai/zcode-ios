#!/bin/sh
# Throwaway Git repository with known files, used to record the `git-files` fixtures with nothing personal:
#   Probe/make-fixture-repo.sh
#   REPO=/private/tmp/zcode-fixture-repo NOREPO=/private/tmp/zcode-fixture-norepo \
#     swift run zcode-probe run Probe/git-files.json --record /tmp/zcode-fixture-rec
# then clean up (see Tests/Fixtures/README.md) and delete both directories.
set -eu
REPO=/private/tmp/zcode-fixture-repo
NOREPO=/private/tmp/zcode-fixture-norepo
rm -rf "$REPO" "$NOREPO"
mkdir -p "$REPO/src" "$NOREPO"
cd "$REPO"
git init -q -b main
git config user.email fixture@example.com
git config user.name Fixture
printf '# Démo\n\nLigne 1\nLigne 2\nLigne 3\n' > README.md
printf 'func salut() {\n    print("bonjour")\n}\n' > src/app.swift
printf 'secret=non\n' > .hidden
printf 'a\nb\nc\n' > old.txt
head -c 300 /dev/urandom > logo.bin
# 1,500 lines of 99 "é" (2 bytes each): the 262,144-byte read splits an "é" in two.
python3 -c "print(('é' * 99 + '\n') * 1500, end='')" > big.txt
git add -A
git commit -qm init
printf '# Démo\n\nLigne 1\nLigne 2 modifiée\nLigne 3\nLigne 4\n' > README.md
printf 'func salut() {\n    print("bonjour, monde")\n}\n' > src/app.swift
git add src/app.swift
git mv old.txt renamed.txt
printf 'nouveau\nfichier\n' > new.txt
head -c 300 /dev/urandom > logo.bin
printf 'x\n' > "$NOREPO/a.txt"
git status --short
