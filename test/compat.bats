#!/usr/bin/env bats
# Cross-version tests: this build's client against daemons started by older
# zmx releases. A daemon keeps the binary it was started from, so after an
# upgrade every running session is served by an old daemon while `zmx list`,
# `attach`, `send` and `history` come from the new binary.
#
# ZMX_OLD_BINS is a space-separated list of old zmx binaries. Without it the
# suite skips; CI downloads the previous fork release and the last pre-freeze
# release (v0.8.1-fork.f2df749, legacy wire header) into it.

load test_helper

old_bins() {
  [[ -n "${ZMX_OLD_BINS:-}" ]] || skip "ZMX_OLD_BINS not set"
  echo "$ZMX_OLD_BINS"
}

start_old() {
  local old="$1" name="$2"
  "$old" run "$name" -d true >/dev/null 2>&1
  wait_for_session "$name"
}

@test "compat: list reaches sessions started by older releases" {
  local i=0
  for old in $(old_bins); do
    start_old "$old" "old-list-$i"
    run "$ZMX" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"name=old-list-$i"$'\t'"pid="* ]]
    [[ "$output" != *"err="* ]]
    i=$((i + 1))
  done
}

@test "compat: send and history work on an old session" {
  local i=0
  for old in $(old_bins); do
    start_old "$old" "old-io-$i"
    "$ZMX" send "old-io-$i" $'echo compat-marker-'"$i"$'\r'
    wait_for_output "old-io-$i" "compat-marker-$i"
    i=$((i + 1))
  done
}

@test "compat: labels round-trip on an old session" {
  local i=0
  for old in $(old_bins); do
    start_old "$old" "old-label-$i"
    run "$ZMX" set "old-label-$i" "k=v$i"
    [ "$status" -eq 0 ]
    run "$ZMX" get "old-label-$i" k
    [ "$status" -eq 0 ]
    [[ "$output" == "v$i" ]]
    i=$((i + 1))
  done
}

@test "compat: attach restores and drives an old session" {
  command -v python3 >/dev/null || skip "python3 not available"
  local i=0
  for old in $(old_bins); do
    start_old "$old" "old-attach-$i"
    run python3 - "$ZMX" "old-attach-$i" <<'EOF'
import os, pty, select, sys, time
zmx, sess = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(zmx, [zmx, "attach", sess])
out = b""
def pump(secs):
    global out
    end = time.time() + secs
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                out += os.read(fd, 65536)
            except OSError:
                return
pump(1.0)
os.write(fd, b"echo attach-marker-$((6*7))\r")
pump(1.5)
os.write(fd, b"\x1c")  # ctrl-\ detaches
pump(1.0)
sys.exit(0 if b"attach-marker-42" in out else 1)
EOF
    [ "$status" -eq 0 ]
    i=$((i + 1))
  done
}

@test "compat: kill stops an old session" {
  local i=0
  for old in $(old_bins); do
    start_old "$old" "old-kill-$i"
    run "$ZMX" kill "old-kill-$i"
    [ "$status" -eq 0 ]
    run "$ZMX" list --short
    [[ "$output" != *"old-kill-$i"* ]]
    i=$((i + 1))
  done
}
