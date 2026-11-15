#!/usr/bin/env bash
# Tests the compiler zcaml's dune locks (build/dune/path_compiler.ml), with
# `dune pkg lock` and `dune build`'s auto-locking, against an opam repository
# of fake packages: `ocaml-system` with a zcaml toolchain on PATH, unless the
# project can't use it, otherwise as upstream, `ocaml-base-compiler`.
#
#   scripts/test-dune-pkg.sh <dune-exe> <toolchain>
#
# <toolchain> is a native zcaml toolchain (its `bin` has `ocamlc`). No network.
set -euo pipefail

dune="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
toolchain_bin="$(cd "$2/bin" && pwd)"
version="$("$toolchain_bin/ocamlc" -vnum)"
newer=99.0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export XDG_CACHE_HOME="$work/cache"
unset ZCAML_NO_PATH_COMPILER OCAMLPATH OCAMLFIND_CONF

# The repository: `ocaml` of the toolchain's version and a newer one (upstream's
# choice), `linux-only` (no solution elsewhere), and `pick` (elsewhere, only
# with `ocaml-base-compiler`).
pkg() {
  mkdir -p "$work/repo/packages/$1/$1.$2"
  { echo 'opam-version: "2.0"'; cat; } >"$work/repo/packages/$1/$1.$2/opam"
}
mkdir -p "$work/repo" && echo 'opam-version: "2.0"' >"$work/repo/repo"
for v in "$version" "$newer"; do
  pkg ocaml "$v" <<<"depends: [ \"ocaml-base-compiler\" {= \"$v\"} | \"ocaml-system\" {= \"$v\"} ]"
  pkg ocaml-base-compiler "$v" <<<$'flags: compiler\nconflict-class: "ocaml-core-compiler"'
done
pkg ocaml-system "$version" <<EOF
flags: compiler
conflict-class: "ocaml-core-compiler"
available: sys-ocaml-version = "$version"
EOF
pkg linux-only 1 <<<$'depends: [ "ocaml" ]\navailable: os = "linux"'
pkg pick 1 <<<'depends: [ "ocaml-base-compiler" ]'
pkg pick 2 <<<$'depends: [ "ocaml" ]\navailable: os = "linux"'

# check <name> <depends> <expected compiler> <lock_dir fields> [<env>...]: locks
# a project of <depends>, both ways, with the toolchain on PATH.
check() {
  local name="$1" depends="$2" expected="$3" fields="$4"
  shift 4
  local dir="$work/$name"
  mkdir -p "$dir"
  printf '(lang dune 3.20)\n(package (name p) (allow_empty) (depends %s))\n' "$depends" >"$dir/dune-project"
  for how in lock auto; do
    rm -rf "$dir/dune.lock" "$dir/_build"
    printf '(lang dune 3.20)\n(repository (name fixture) (url file://%s))\n(lock_dir (repositories fixture)%s)\n%s\n' \
      "$work/repo" "$fields" "$([[ $how == auto ]] && echo '(pkg enabled)')" >"$dir/dune-workspace"
    local lock_dir=dune.lock
    if [[ $how == lock ]]; then
      (cd "$dir" && env "$@" "$dune" pkg lock >"$dir/log" 2>&1)
    else
      lock_dir=_build/_private/default/.lock/dune.lock
      (cd "$dir" && env "$@" "$dune" build "$lock_dir" >"$dir/log" 2>&1)
    fi
    local got
    got="$(cd "$dir/$lock_dir" && for f in ocaml-system.*.pkg ocaml-base-compiler.*.pkg; do
      if [[ -e $f ]]; then echo "${f%.pkg}"; fi
    done | sort -u | tr '\n' ' ')"
    if [[ "${got% }" != "$expected" ]]; then
      echo "error: $name ($how): locked '${got% }', expected '$expected'" >&2
      cat "$dir/log" >&2
      exit 1
    fi
    echo "ok: $name ($how): $expected"
  done
}

on_path="PATH=$toolchain_bin:/usr/bin:/bin"
check toolchain 'ocaml' "ocaml-system.$version" '' "$on_path"
check opt-out 'ocaml' "ocaml-base-compiler.$newer" '' "$on_path" ZCAML_NO_PATH_COMPILER=1
check no-toolchain 'ocaml' "ocaml-base-compiler.$newer" '' PATH=/usr/bin:/bin
check other-version "(ocaml (= $newer))" "ocaml-base-compiler.$newer" '' "$on_path"
check explicit 'ocaml' "ocaml-base-compiler.$newer" ' (constraints (ocaml-base-compiler (>= 0)))' "$on_path"
# Platforms without a solution either way don't count; ones with, do.
platforms=' (solve_for_platforms ((arch x86_64) (os linux)) ((arch x86_64) (os win32)))'
check unsolved-elsewhere 'ocaml linux-only' "ocaml-system.$version" "$platforms" "$on_path"
check solved-elsewhere 'ocaml pick' "ocaml-base-compiler.$newer" "$platforms" "$on_path"
