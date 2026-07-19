#!/bin/bash
# backup.sh — one command to save + push everything to GitHub.
# Run from Terminal: bash backup.sh
# (First time only, you can also run: chmod +x backup.sh
#  and then just do: ./backup.sh)

set -e
cd "$(dirname "$0")"

echo "Staging all changes..."
git add -A

if git diff --cached --quiet; then
  echo "Nothing new to back up — already up to date."
  exit 0
fi

TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
git commit -m "backup: $TIMESTAMP"

echo "Pushing to GitHub..."
git push origin main

echo ""
echo "✅ Backed up. GitHub now has commit:"
git rev-parse HEAD
