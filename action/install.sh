#!/usr/bin/env bash
# The action's first step: installs the zcaml CLI for the runner and puts it on
# the job's PATH. Which one is the action's own pin: the release ./SHA256SUMS is
# the checksums of (see RELEASING.md), so a workflow that pins the action pins
# the CLI. The toolchains are zcaml.dev's index's (the `ocaml` input pins one).
#
#   ZCAML_RELEASES_URL  where the releases are, instead of zcaml's on GitHub:
#                       <url>/zcaml-v<version>/<archive>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
releases="${ZCAML_RELEASES_URL:-https://github.com/zcaml/zcaml/releases/download}"

fail() {
  echo "::error::$*"
  exit 1
}

case "$RUNNER_OS" in
  Linux) os=linux ;;
  macOS) os=macos ;;
  Windows) os=windows ;;
  *) fail "zcaml has no build for $RUNNER_OS" ;;
esac
case "$RUNNER_ARCH" in
  X64) arch=x86_64 ;;
  ARM64) arch=aarch64 ;;
  *) fail "zcaml has no build for $RUNNER_ARCH" ;;
esac

[[ -f "$here/SHA256SUMS" ]] || fail "this version of the action is of no zcaml release: use a released one (zcaml/zcaml@v1)"
line="$(grep -E "^[0-9a-f]{64}  zcaml-[0-9]+\.[0-9]+\.[0-9]+-$arch-$os\.(tar\.gz|zip)\$" "$here/SHA256SUMS" || true)"
[[ -n "$line" ]] || fail "zcaml has no build for $arch-$os"
sha256="${line%% *}"
archive="${line##* }"
version="${archive#zcaml-}"
version="${version%"-$arch-$os."*}"

dir="$RUNNER_TEMP/zcaml-$version"
rm -rf "$dir"
mkdir -p "$dir"
curl -fsSL --retry 3 -o "$dir/$archive" "$releases/zcaml-v$version/$archive"
# From stdin: Git Bash's escapes a path with a `\`, and so the line.
if command -v sha256sum >/dev/null; then
  got="$(sha256sum <"$dir/$archive")"
else
  got="$(shasum -a 256 <"$dir/$archive")"
fi
[[ "${got%% *}" == "$sha256" ]] || fail "$archive isn't the released one: its SHA-256 is ${got%% *}, not $sha256"
case "$archive" in
  *.zip) unzip -q "$dir/$archive" -d "$dir" ;;
  *) tar -xzf "$dir/$archive" -C "$dir" ;;
esac
rm "$dir/$archive"

echo "$dir/bin" >>"$GITHUB_PATH"
"$dir/bin/zcaml" --version

# dune pkg builds a project's packages where paths can be longer than 260
# characters, which Windows only takes from programs when this is on. A
# runner's an administrator; one that isn't gets zcaml's warning instead.
if [[ "$os" == windows ]]; then
  key='HKLM\SYSTEM\CurrentControlSet\Control\FileSystem'
  if ! reg query "$key" //v LongPathsEnabled 2>/dev/null | grep -q '0x1'; then
    if reg add "$key" //v LongPathsEnabled //t REG_DWORD //d 1 //f >/dev/null 2>&1; then
      echo "::notice::zcaml turned on Windows' long paths (LongPathsEnabled), for dune pkg's builds"
    else
      echo "::warning::Windows' long paths are off, and turning them on needs an administrator: dune pkg's builds may fail"
    fi
  fi
fi
