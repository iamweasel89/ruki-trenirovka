#!/usr/bin/env bash
# Local twin of proverka-gigieny.ps1 (same pattern file), for machines without PowerShell
cd "$(dirname "$0")/.." || exit 2
mapfile -t P < <(grep -v '^#' ci/gigiena-shablony.txt | grep -v '^$')
n=0; files=$( (git ls-files; git ls-files --others --exclude-standard) | sort -u | grep -v "^ci/gigiena-shablony.txt$")
for p in "${P[@]}"; do
  out=$(echo "$files" | xargs -r grep -nPi -- "$p" 2>/dev/null) && { echo "NAIDENO [$p]:"; echo "$out"; n=$((n+1)); }
done
echo "gigiena: shablonov s nahodkami $n"
[ "$n" -eq 0 ]
