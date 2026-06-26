#!/bin/bash
# secret-scan.sh — the anonymity release gate.
# Scans every git-tracked file for box-specific hostnames, real emails, tokens, and private
# infrastructure names. Exits non-zero on any hit. Run before every push.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

# Denylist of patterns that must NEVER appear in a tracked file.
# (example.com / example.org are the ALLOWED public placeholders.)
PATTERNS=(
  'haggis\.top'
  'wanderingmonster'
  'palladium'
  'restorebritain'
  'identicore'
  'cognitionfacility'
  'alba\.win'
  'your@email\.com'
  # token shapes
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'gho_[A-Za-z0-9]{20,}'
  'glpat-[A-Za-z0-9_-]{20,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'AKIA[0-9A-Z]{16}'
  'BEGIN (RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY'
)

fail=0
# Scan the tracked set only (untracked/gitignored local notes are intentionally excluded).
# The scanner excludes itself: its own denylist legitimately contains the forbidden patterns.
mapfile -t files < <(git ls-files | grep -vx 'test/secret-scan.sh')
if [[ ${#files[@]} -eq 0 ]]; then
  echo "secret-scan: no tracked files yet (nothing to scan)"; exit 0
fi

for pat in "${PATTERNS[@]}"; do
  # -I skips binary files (e.g. logo.png). -n shows line numbers.
  if hits=$(grep -InEH "$pat" "${files[@]}" 2>/dev/null); then
    echo "✗ FORBIDDEN PATTERN  /$pat/"
    echo "$hits" | sed 's/^/    /'
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo
  echo "secret-scan FAILED — anonymize the above before pushing."
  exit 1
fi
echo "secret-scan OK — ${#files[@]} tracked files clean."
