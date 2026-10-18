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
- `fix(attach): switch sessions only from the session's own terminal` — a
  program that inherits `ZMX_SESSION` and runs `zmx attach other` on a terminal
  of its own (an agent's tool sandbox) gets its own client instead of moving the
  session's leader client to `other`.
- `fix(ipc): keep talking to daemons started before the wire freeze` — upstream
  35b8783 moved the IPC header length from bytes 1-4 to 4-7 and marked it
  "existing daemons must be killed". A daemon keeps the binary it was started
  from, so after an upgrade every running session answered `err=Unexpected` and
  re-attached panes stayed blank. `ipc.connectSession` now probes each daemon
  once and speaks the legacy header to old ones (`ipc.Wire`);
  `test/compat.bats` covers it against older releases in CI.

## Release gates

`fork-release.yml` never auto-merges an upstream commit marked
`BREAKING CHANGE`: it fails and opens an issue so the merge is done by hand
with whatever keeps old daemons reachable. Every release also runs
`test/compat.bats` against daemons started by the previous release and by
`v0.8.1-fork.f2df749`.
