#!/usr/bin/env bash
# The action's second step: `zcaml dist`, with the action's inputs as its
# arguments, and the files it made as the step's `artifacts` output.
#
#   INPUT_OCAML    --ocaml
#   INPUT_TARGETS  -t: comma or space separated
#   INPUT_TEST     --test: one per line
set -euo pipefail

targets="$(printf '%s' "$INPUT_TARGETS" | tr -s ' \t\r\n,' ',')"
targets="${targets#,}"
args=(--ocaml "$INPUT_OCAML" -t "${targets%,}")
while IFS= read -r test; do
  test="${test%$'\r'}"
  [[ -z "${test//[[:space:]]/}" ]] || args+=(--test "$test")
done <<<"$INPUT_TEST"

# zcaml's standard output: what it made.
artifacts="$(zcaml dist "${args[@]}")"
echo "$artifacts"
{
  echo "artifacts<<zcaml-artifacts"
  echo "$artifacts"
  echo "zcaml-artifacts"
} >>"$GITHUB_OUTPUT"
