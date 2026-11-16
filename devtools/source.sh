#!/usr/bin/env bash
# A dev tool (devtools.txt) as a dune pkg project, for `zcaml dist` to build for
# every host: its release's sources as the project, so its executables are each
# target's (as a dependency's, they'd be the build machine's), with a
# dune-workspace of pinned repositories.
#
#   devtools/source.sh <work-dir> <package> <version>
#
# The project is <work-dir>/src, without a lock directory: `dune pkg lock` there,
# with zcaml's dune.
#
#   TARGETS  the targets the lock directory is for, besides x86_64-linux-gnu
#   OVERLAY, OVERLAYS  as scripts/repositories.sh's
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
work="$(cd "$1" && pwd)"
package="$2"
version="$3"
export TARGETS="${TARGETS:-}"

read -r url sha256 < <(awk -v p="$package" -v v="$version" '$1 == p && $2 == v { print $6, $7 }' "$here/devtools.txt")
if [[ -z "${url:-}" ]]; then
  echo "error: $package $version isn't in devtools.txt" >&2
  exit 1
fi

src="$work/src"
rm -rf "$src"
mkdir -p "$src"
curl -fsSL "$url" -o "$work/source"
echo "$sha256  $work/source" | sha256sum -c --quiet
tar -xaf "$work/source" -C "$src" --strip-components=1

# shellcheck source=../scripts/repositories.sh
source "$here/../scripts/repositories.sh"
{
  echo "(lang dune 3.24)"
  cat "$work/repositories.dune"
} >"$src/dune-workspace"
