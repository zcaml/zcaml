# Sourced: writes $work/repositories.dune, a dune-workspace's repositories and
# lock directory for cross-compiling dune pkg's packages with zcaml's OCaml 5.5.1
# toolchains: for scripts/cross-env.sh (ecosystem/run.sh) and devtools/source.sh.
# Takes
#
#   $work        where it writes repositories.dune
#   TARGETS      the targets, besides this machine (x86_64-linux-gnu)
#   OVERLAY      zcaml's overlay, default: this checkout's; empty: none
#   OVERLAYS     more opam repositories, ahead of it: `<name>=<url>`s

# A target's platform, as the lock directory's solutions are for: opam's names.
platform() {
  case "$1" in
    x86_64-linux-gnu | x86_64-linux-musl) echo '((arch x86_64) (os linux))' ;;
    aarch64-linux-gnu | aarch64-linux-musl) echo '((arch arm64) (os linux))' ;;
    x86_64-windows-gnu) echo '((arch x86_64) (os win32) (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc))' ;;
    x86_64-macos-none) echo '((arch x86_64) (os macos))' ;;
    aarch64-macos-none) echo '((arch arm64) (os macos))' ;;
    *) echo "error: no platform for $1" >&2; exit 1 ;;
  esac
}
platforms="$(for target in x86_64-linux-gnu $TARGETS; do platform "$target"; done | sort -u | tr '\n' ' ')"

# $OVERLAYS, zcaml's overlay, then dune's default repositories, at fixed commits:
# a build doesn't depend on when it ran. The compiler is the toolchain's
# `ocaml-system`, explicitly: zcaml's dune (from 3.24.2+zcaml.6) prefers it
# anyway, but builds another compiler for a project that can't use it, and older
# releases don't.
zcaml_overlay="${OVERLAY-$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay" && pwd)}"
overlays=""
for overlay in ${OVERLAYS:-} ${zcaml_overlay:+"zcaml=file://$(cd "$zcaml_overlay" && pwd)"}; do
  printf '(repository\n (name %s)\n (url %s))\n' "${overlay%%=*}" "${overlay#*=}"
  overlays="$overlays ${overlay%%=*}"
done >"$work/repositories.dune"
cat >>"$work/repositories.dune" <<EOF2
(repository
 (name overlay-pinned)
 (url git+https://github.com/ocaml-dune/opam-overlays.git#99fc2e18c45b4761ed5f6d282910c03c97e32bce))
(repository
 (name relocatable-pinned)
 (url git+https://github.com/ocaml-dune/opam-repository-relocatable.git#d64df82c7e16de819a770cabf4066a06243ed80b))
(repository
 (name upstream-pinned)
 (url git+https://github.com/ocaml/opam-repository.git#d74e2449deccd679e0a28814bfc75ba47656a7b2))
(lock_dir
 (repositories$overlays overlay-pinned relocatable-pinned upstream-pinned)
 (solver_env (sys-ocaml-version 5.5.1))
 (solve_for_platforms $platforms)
 (constraints (ocaml-system (= 5.5.1))))
EOF2
