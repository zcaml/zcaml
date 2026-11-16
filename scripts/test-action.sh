#!/usr/bin/env bash
# Checks what the action says it made (its `artifacts` output), in the project's
# directory: an archive per target, and their checksums.
#
#   ARTIFACTS=<the output> scripts/test-action.sh <targets>
set -euo pipefail

expected="$1"
count=0
sums=""
while read -r artifact; do
  # Windows' paths.
  artifact="${artifact//\\//}"
  artifact="${artifact%$'\r'}"
  if [[ ! -f "$artifact" ]]; then
    echo "error: the action's output has $artifact, which isn't a file" >&2
    exit 1
  fi
  case "$artifact" in
    */SHA256SUMS) sums="$artifact" ;;
    *) count=$((count + 1)) ;;
  esac
done <<<"$ARTIFACTS"
if [[ $count -ne $expected || -z "$sums" ]]; then
  echo "error: the action's output isn't $expected archives and SHA256SUMS:" >&2
  echo "$ARTIFACTS" >&2
  exit 1
fi
if [[ "$(wc -l <"$sums")" -ne $expected ]]; then
  echo "error: $sums isn't of $expected archives:" >&2
  cat "$sums" >&2
  exit 1
fi
echo "ok: $count archives, $sums"
