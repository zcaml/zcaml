# Sourced: sets up cross-compiling dune pkg's packages with a zcaml release's
# toolchains, for ecosystem/run.sh. Takes
#
#   $work        where it writes findlib.conf and repositories.dune
#   $toolchains  a toolchain per target, `target-<triple>`, for this machine
#                (x86_64-linux-gnu, whose own is the native one): a release's
#                `ocaml-<version>-host-x86_64-linux-gnu-target-<triple>.tar.zst`s
#   $dune_bin    zcaml's dune
#   TARGETS      the targets, besides this machine
#   OVERLAY, OVERLAYS  as repositories.sh's
#
# repositories.dune is a dune-workspace's repositories and lock directory
# (repositories.sh).

# The toolchains, as a findlib configuration: `-x <triple, with _ for ->` builds
# with target-<triple>'s (findlib's names can't have `-`). The native one is also
# first on PATH: the lock directory's `ocaml-system`.
toolchain() {
  local name="$1" dir="$toolchains/target-$2"
  local suffix="${name:+($name)}"
  echo "path$suffix=\"$dir/lib/ocaml\""
  [[ -z "$name" ]] || echo "destdir$suffix=\"$dir/lib/ocaml\""
  for tool in ocamlc ocamlopt ocamldep; do echo "$tool$suffix=\"$dir/bin/$tool.opt\""; done
  echo "ocamlmklib$suffix=\"$dir/bin/ocamlmklib\""
}
{
  toolchain "" x86_64-linux-gnu
  for target in $TARGETS; do toolchain "${target//-/_}" "$target"; done
} >"$work/findlib.conf"

path="$dune_bin:$toolchains/target-x86_64-linux-gnu/bin"
for target in $TARGETS; do path="$path:$toolchains/target-$target/bin"; done
export PATH="$path:$PATH"
unset OCAMLPATH OCAMLLIB OCAMLFIND_CONF DUNE_CACHE_ROOT
export OCAMLFIND_CONF="$work/findlib.conf"
# Fresh: dune's cache (shared by the packages, as by a user's projects), and its
# copies of the repositories.
export XDG_CACHE_HOME="$work/cache"
export WINEPREFIX="$work/wine" WINEDEBUG=-all

# shellcheck source=repositories.sh
source "$(dirname "${BASH_SOURCE[0]}")/repositories.sh"
