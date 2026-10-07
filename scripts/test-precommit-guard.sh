#!/usr/bin/env bash
# Known-bad / known-good test for the personal-data pre-commit guard
# (.githooks/pre-commit). A guard that has only ever passed is an untested
# claim — this proves it still BLOCKS the inputs it is supposed to block and
# still ALLOWS ordinary content.
#
# Run:  scripts/test-precommit-guard.sh
#
# Works in a throwaway clone under /tmp. Never pushes. Never touches the
# working repo. All values below are synthetic.
set -uo pipefail

SRC=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
D=$(mktemp -d /tmp/precommit-guard-test.XXXXXX)
trap 'rm -rf "$D"' EXIT

git clone --quiet --single-branch "file://$SRC" "$D" || { echo "clone failed"; exit 1; }
cd "$D" || exit 1
git config core.hooksPath .githooks
git config user.email "hook.test@example.com"
git config user.name "Hook Test"

pass=0; fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then
    printf 'PASS  %-38s (%s)\n' "$1" "$2"; pass=$((pass+1))
  else
    printf 'FAIL  %-38s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}
attempt() { if git commit --quiet -m "guard test" >/dev/null 2>&1; then echo allowed; else echo blocked; fi; }
cleanup() {
  git reset --quiet HEAD -- . 2>/dev/null
  git checkout --quiet -- . 2>/dev/null
  git clean -qfd 2>/dev/null
}

# --- MUST BLOCK -------------------------------------------------------------
printf 'owner contact: synthetic.user@gmail.com\n' > note.md
git add note.md; check "email in .md" blocked "$(attempt)"; cleanup

printf 'full_name,email\nA B,synthetic.user@gmail.com\n' > roster.csv
git add -f roster.csv; check "data file (.csv)" blocked "$(attempt)"; cleanup

printf 'reach me on +63 917 123 4567 any time\n' > note.md
git add note.md; check "international phone" blocked "$(attempt)"; cleanup

# --- MUST ALLOW -------------------------------------------------------------
printf 'support: help@example.com\n' > note.md
git add note.md; check "placeholder-domain email" allowed "$(attempt)"; cleanup

# --- KNOWN GAPS (documented in docs/SECURITY.md; asserted so that silently
# --- closing one shows up here as a FAIL and the docs get updated) -----------
printf 'reach me on 09171234567 any time\n' > note.md
git add note.md; check "local-format phone [known gap]" allowed "$(attempt)"; cleanup

printf 'Prepared by Maria Santos Dela Cruz\n' > note.md
git add note.md; check "bare personal name [known gap]" allowed "$(attempt)"; cleanup

printf 'owner contact: synthetic.user@gmail.com\n' > note.md
git add note.md
if git commit --quiet --no-verify -m "bypass test" >/dev/null 2>&1; then r=allowed; else r=blocked; fi
check "--no-verify bypass [known gap]" allowed "$r"; cleanup

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
