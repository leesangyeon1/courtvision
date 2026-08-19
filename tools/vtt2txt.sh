#!/usr/bin/env bash
# Strip a YouTube auto-caption .vtt down to plain text.
# Handles the rolling-caption format: each line appears in 2-3 consecutive
# cues, so drop tags/timings first, then collapse consecutive duplicates.
set -euo pipefail
for f in "$@"; do
  sed -E -e '/^WEBVTT|^Kind:|^Language:/d' \
         -e '/-->/d' \
         -e 's/<[^>]*>//g' \
         -e 's/&nbsp;/ /g; s/&amp;/\&/g; s/&#39;/'"'"'/g; s/&quot;/"/g' \
         -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \
         "$f" \
  | awk 'NF { if ($0 != p) print; p = $0 }' > "${f%.vtt}.txt"
done
