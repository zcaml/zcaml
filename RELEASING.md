# Releasing zcaml

Each distribution releases on its own, from a tag; the overlay publishes itself
from `main`. For local builds and checks, see [Contributing](CONTRIBUTING.md).

| Distribution | Tag | Workflow |
|---|---|---|
| OCaml | `ocaml-v<version>[-<revision>]` | [`toolchains.yml`](.github/workflows/toolchains.yml) |
| Dune | `dune-v<version>-zcaml.<revision>` | [`dune.yml`](.github/workflows/dune.yml) |
| Developer tool | `<package>-v<version>-zcaml.<revision>` | [`devtools.yml`](.github/workflows/devtools.yml) |
| CLI | `zcaml-v<version>` | [`cli.yml`](.github/workflows/cli.yml) |
| Action | `v<version>`, and `v1` | none: it's the repository at the tag |

The revision counts zcaml's builds of one upstream version: `ocaml-v5.5.1` is
the first of OCaml 5.5.1 and `ocaml-v5.5.1-2` the second, while Dune's and the
tools' start at `zcaml.1`. Dune's is also in `dune --version`
(`3.24.2+zcaml.7`, `+` for the tag's `-`).

To release: prepare the component (below), optionally try the workflow on a
branch, which builds and tests without publishing, then push the tag:

```sh
gh workflow run toolchains.yml --ref <branch> -f ocaml_version=5.5.1
gh workflow run dune.yml --ref <branch> -f ocaml_tag=ocaml-v5.5.1-8
gh workflow run devtools.yml --ref <branch> -f package=ocamlformat -f version=0.29.0
gh workflow run cli.yml --ref <branch>

git tag <tag> && git push origin <tag>
```

CI publishes the GitHub Release once every build and test passes. Re-running a
tag's workflow uploads over its assets (`--clobber`), e.g. to finish a failed
run.

When updating everything, the order is OCaml, then Dune (bootstrapped with the
latest OCaml release), then the developer tools and their overlay packages, then
the CLI and the action. Each OCaml and dune release is in zcaml.dev's index as
soon as it's published ([below](#the-index)): the CLI installs it from then on.

## OCaml toolchains

- A new upstream version: add its `ocaml_*` dependency to
  [`build.zig.zon`](build.zig.zon), first (the newest is the default), run
  `zig build generate` for its manifest in `build/ocaml/manifests/`, adapt
  `build/ocaml/` to upstream's build changes, and add it to `toolchains.yml`'s
  `ocaml_version` choices.
- A rebuild: just the next revision's tag.

CI builds the full matrix on Linux and verifies the Linux-hosted toolchains
(natively, QEMU, Wine), then the macOS- and Windows-hosted ones on macOS (with
Rosetta) and Windows. Test programs compiled for an OS other than the verifying
one run where they can, before publishing
`ocaml-<version>-host-<host>-target-<target>.tar.zst` archives. The archive names
have no revision: link to the tag's release.

## Dune

- Pin the Dune release in `build.zig.zon` and set `revision` in
  [`build/dune/tool.zig`](build/dune/tool.zig) (1 for a new upstream version).
- A new upstream Dune: check that `addCrossHooks`' and `addPathCompilerHooks`'
  replacements still apply (the build fails if one doesn't), and test
  cross-compiling packages and locking with a toolchain on `PATH` (CI runs
  `scripts/test-dune-pkg.sh`).

CI bootstraps all seven hosts' Dune on Linux with the latest `ocaml-v*` release
(or the `ocaml_tag` input), smoke-tests them (distro containers, Wine, macOS
with Rosetta), checks the tag names the built version, and publishes
`dune-<version>-zcaml.<revision>-<host>.tar.zst`, each with `bin/dune`. Dune
works with any OCaml version.

## Developer tools

1. Add the tool's line to [`devtools/devtools.txt`](devtools/devtools.txt):
   `<package> <version> <ocaml> <license> <homepage> <source-url> <sha256>`,
   `<ocaml>` being the OCaml release it's for (`5.5` for ocaml-lsp-server) or
   `-` for any (ocamlformat).
2. Check `devtools.yml`'s `OCAML_VERSION`: it must be
   [`scripts/repositories.sh`](scripts/repositories.sh)'s, 5.5.1, and one
   the index has. The toolchains and dune are the index's newest: the workflow
   builds the tag's `zcaml` and runs it.
3. Put any fixes the build needs in `overlay/`. A new tool also needs a tag
   trigger in `devtools.yml` and a test in [`devtools/test.sh`](devtools/test.sh).

CI makes a dune pkg project of the tool's sources
([`devtools/source.sh`](devtools/source.sh)), locks it, builds it for all seven
hosts with `zcaml dist`, tests them (formatting a snippet, answering an LSP
initialize), and publishes
`<package>-<version>-zcaml.<revision>-<host>.tar.gz` (dune pkg doesn't extract
`.tar.zst`), each with the tool's files and an install file, and `SHA256SUMS`.

**Then, by hand**, make the overlay's binary packages of the release:

```sh
devtools/overlay.sh <tag>
```

It writes `overlay/packages/<package>/<package>.<version>+zcaml.<revision>-<host>/`
from the release's `SHA256SUMS`. Add the version to `overlay/README.md`'s
pre-built table and commit to `main`.

## The CLI

1. Set `version` in [`build.zig.zon`](build.zig.zon): the tag has to name it.
2. Push `zcaml-v<version>`.

The CLI installs what zcaml.dev's index has, not releases of its own: a CLI
release is for the CLI's changes. Before publishing, CI checks that
`index.pub` verifies the live index.

CI cross-compiles `zcaml` for five hosts on Linux (x86_64 and aarch64 Linux,
static, for glibc and musl systems; both macOS; x86_64 Windows), then tests each
on its host: [`scripts/test-cli.sh`](scripts/test-cli.sh) builds
[`test/cli/hello`](test/cli/hello) with `zcaml dist` for the host and other
targets, and the action installs the build and does the same. It publishes
`zcaml-<version>-<host>.tar.gz` (`.zip` for Windows), each with `bin/zcaml`, and
`SHA256SUMS`.

`test/cli/hello`'s lock directory is committed, for the OCaml version
`scripts/test-cli.sh` names: relock it (`dune pkg lock` there, with `zcaml env`'s
dune) when the index drops that version.

### The action

[`action.yml`](action.yml) is used from this repository, `zcaml/zcaml@v1`. It
installs the CLI release whose checksums are in `action/SHA256SUMS`, and no
other, so a workflow that pins the action pins the CLI. The toolchains are the
index's: `ocaml: 5.5.1-13` pins one. **After a CLI release, by hand:**

```sh
gh release download zcaml-v<version> -p SHA256SUMS -D action --clobber
git commit -m "action: zcaml <version>" action/SHA256SUMS
git tag v<action-version> && git push origin main v<action-version>
git tag -f v1 v<action-version> && git push -f origin v1
```

The action's version is its own (`v1.0.0`, `v1.0.1`, ...): its inputs are its
interface, whichever CLI it runs. `v1` is the one tag that moves, to the latest
`v1.*`. `cli.yml` has tested the action with the build already, from the
archives (`ZCAML_RELEASES_URL`).

## The overlay

[`overlay.yml`](.github/workflows/overlay.yml) mirrors `overlay/` to
[`zcaml-overlay`](https://github.com/zcaml/zcaml-overlay)'s `main` on
each push to `main` that changes it (`git subtree split`, fast-forward only,
with the `OVERLAY_DEPLOY_KEY` deploy key); `gh workflow run overlay.yml` retries
it. It doesn't test packages: run the affected ones through the ecosystem probes
first, on Depot CI:

```sh
depot ci dispatch --repo zcaml/zcaml --workflow ecosystem.yml --ref main \
  --input packages="<packages>"
```

## After a release

Point what builds with it at the new release:

- **OCaml:** `ocaml_tag`'s default and `OCAML_TAG` in
  [`.depot/workflows/ecosystem.yml`](.depot/workflows/ecosystem.yml). For a new
  OCaml version, also its `5.5.1` in `scripts/repositories.sh`, `devtools.yml`'s
  `OCAML_VERSION`, `scripts/test-cli.sh` and `test/cli/hello`'s lock directory,
  and `toolchains.yml`'s default.
- **Dune:** `dune_tag`'s default and `DUNE_TAG` in
  `.depot/workflows/ecosystem.yml`.
- **Any:** the download table in [`README.md`](README.md).

### The index

`https://zcaml.dev/index/v1.json` is what the CLI installs: every OCaml and
dune release since the oldest in [`build/index.zig`](build/index.zig), the Zig
and macOS SDK each toolchain was built with (its tag's `build.zig.zon`'s), each
archive by its SHA-256. `--ocaml 5.5.1` is the newest revision of 5.5.1,
`--ocaml 5.5.1-13` that one; dune is the newest. A release that's a draft or a
prerelease isn't in it.

[`site.yml`](.github/workflows/site.yml) writes it (`zig build index -- <out>`),
signs it with minisign and deploys it with [`site/`](site/) to GitHub Pages,
after each OCaml or dune release, and when they change on `main`. The CLI
refuses an index that isn't signed with the key in
[`index.pub`](index.pub), or that's older (by its `serial`) than one it
has fetched.

- **Take a release out:** make it a prerelease (`gh release edit <tag>
  --prerelease`), then `gh workflow run site.yml`.
- **A layout the CLI can't install:** a new index, `v2.json`, with its oldest
  releases; v1's CLIs keep v1's.
- **Locally:** `zig build index -- zig-out/site/index/v1.json`, sign it with a
  key of your own (`minisign -G -W`, then `minisign -S`), and point the CLI at it
  with `ZCAML_INDEX_URL=file://<path>` and `ZCAML_INDEX_KEY=<public key>`.

Setting it up, once:

1. `minisign -G -W -p index.pub -s zcaml-index.key`, commit `index.pub`,
   and keep `zcaml-index.key` offline.
2. Settings → Environments: an `index` environment whose secret
   `ZCAML_INDEX_KEY` is `zcaml-index.key`'s contents, and whose deployment
   branches and tags are `main`, `ocaml-v*` and `dune-v*`. The same rule for
   `github-pages`.
3. Settings → Pages: source GitHub Actions, custom domain `zcaml.dev`, HTTPS
   enforced.

For a developer tool, check the overlay mirror ran, then that a project picks
the binary: `dune tools exec ocamllsp`, or `dune tools install ocamlformat` and
`dune fmt`.
