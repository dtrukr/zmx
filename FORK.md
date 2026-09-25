# dtrukr/zmx

Upstream [neurosnap/zmx](https://github.com/neurosnap/zmx) `main` plus local patches.
`.github/workflows/fork-release.yml` merges upstream daily, runs unit and
integration tests, and publishes a release when `main` moves. A conflict or a
failing test publishes nothing.

Install the latest build:

    https://github.com/dtrukr/zmx/releases/latest/download/zmx-<os>-<arch>.tar.gz

`<os>` is `macos` or `linux` (static musl), `<arch>` is `aarch64` or `x86_64`.
Each tarball holds a single `zmx` binary and has a `.sha256` next to it.

## Patches on top of upstream

- `fix(attach): don't let terminal query replies claim leadership` — a passive
  viewer's automatic replies (`CSI ? 5 u` etc.) no longer make it the leader and
  resize the session to its window.
