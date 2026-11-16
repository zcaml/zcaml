#!/usr/bin/env bash
# Tests a zcaml CLI end to end, as a CI job uses it: `zcaml dist` of
# test/cli/hello (a dune pkg project, with its lock directory) for this machine
# and other targets, then the archives it made, and `zcaml run`.
#
#   scripts/test-cli.sh <zcaml> [<runner>...]
#
# <runner> runs zcaml, if it doesn't run here: `arch -x86_64`.
#
#   TARGETS        targets to build and test besides this machine, which has to
#                  have what runs them (Wine, QEMU and the target's libraries);
#                  macOS's are skipped but on a Mac
#   BUILD_TARGETS  targets to build only
#
# Needs the network: zcaml installs its toolchains (to $ZCAML_HOME, or the
# user's), dune fetches the project's packages.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
exe="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
# The fixture's lock directory's.
ocaml=5.5.1

fail() {
  echo "error: $*" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -R "$here/../test/cli/hello" "$work/hello"
cd "$work/hello"
# A checkout's, not a build's.
rm -rf _build dist

version="$("$@" "$exe" --version | tr -d '\r')"
[[ "$version" =~ ^zcaml\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$exe --version: '$version'"

# What it can't do, it says before it builds anything.
if "$@" "$exe" dist --ocaml 0.0.0 -t native,nowhere 2>refusal; then
  fail "dist built for OCaml 0.0.0"
fi
grep -q "no OCaml 0.0.0" refusal && grep -q "unknown target 'nowhere'" refusal || {
  cat refusal >&2
  fail "dist didn't say what's wrong with OCaml 0.0.0 and the target 'nowhere'"
}
[[ ! -e _build && ! -e dist ]] || fail "dist built before it refused"

targets="native"
for t in ${TARGETS:-}; do targets="$targets,$t"; done
"$@" "$exe" dist --ocaml "$ocaml" -t "$targets" --test "hello zcaml" --test "hello --version" >artifacts
if [[ -n "${BUILD_TARGETS:-}" ]]; then
  "$@" "$exe" dist --ocaml "$ocaml" -t "${BUILD_TARGETS// /,}" -o dist-built >>artifacts
fi
# Windows' paths.
tr '\\' '/' <artifacts | tr -d '\r' >artifacts.txt

count=0
native=""
while read -r artifact; do
  [[ -f "$artifact" ]] || fail "dist printed $artifact, which isn't a file"
  case "$artifact" in
    */SHA256SUMS) continue ;;
    *.tar.gz) files="$(tar -tzf "$artifact" | sort | tr '\n' ' ')" bin=bin/hello ;;
    *.zip) files="$(unzip -Z1 "$artifact" | sort | tr '\n' ' ')" bin=bin/hello.exe ;;
    *) fail "dist printed $artifact: not an archive" ;;
  esac
  [[ "$files" == "$bin share/hello/greeting.txt " ]] || fail "$artifact has '$files'"
  # This machine's: the one that's none of $TARGETS'.
  if [[ "$artifact" == dist/* ]]; then
    other=""
    for t in ${TARGETS:-}; do
      if [[ "$artifact" == *"-$t."* ]]; then other=1; fi
    done
    [[ -n "$other" ]] || native="$artifact"
  fi
  count=$((count + 1))
done <artifacts.txt
expected=1
for t in ${TARGETS:-} ${BUILD_TARGETS:-}; do expected=$((expected + 1)); done
[[ $count -eq $expected ]] || fail "dist made $count archives, not $expected"

for dir in dist ${BUILD_TARGETS:+dist-built}; do
  grep -q "^$dir/SHA256SUMS$" artifacts.txt || fail "dist didn't print $dir/SHA256SUMS"
  if command -v sha256sum >/dev/null; then
    (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null)
  else
    (cd "$dir" && shasum -a 256 -c SHA256SUMS >/dev/null)
  fi
  [[ ! -e "$dir/.stage" ]] || fail "dist left $dir/.stage"
done

[[ -n "$native" ]] || fail "dist made no archive for this machine"
mkdir extracted
case "$native" in
  *.zip) unzip -q "$native" -d extracted ;;
  *) tar -xzf "$native" -C extracted ;;
esac
bin="$(ls extracted/bin/hello*)"
got="$("$@" "$exe" run "$bin" -- there | tr -d '\r')"
[[ "$got" =~ ^hello,\ there\ \((Unix|Win32)\)$ ]] || fail "zcaml run $bin: '$got'"

# A failing test fails the build, as the test failed.
status=0
"$@" "$exe" dist --ocaml "$ocaml" -t native --test "hello --no-such-option" -o dist-failed >/dev/null 2>&1 || status=$?
[[ $status -ne 0 ]] || fail "dist succeeded with a failing test"
[[ -z "$(ls dist-failed 2>/dev/null)" ]] || fail "dist archived what failed its test: $(ls dist-failed)"

echo "ok: $exe ($version): $(basename "$native")${TARGETS:+, $TARGETS}${BUILD_TARGETS:+, $BUILD_TARGETS}"
