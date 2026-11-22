#!/usr/bin/env bats
# `zmx attach` from inside a session switches the session's client only when
# it was typed at that session's own terminal. A program that inherits
# ZMX_SESSION and attaches on a terminal of its own (an agent's tool sandbox)
# gets its own client instead of moving the person's.

load test_helper

# Drives an outer client on a pty and reports which session it shows after
# `step` runs inside it.
attach_from_inside() {
  python3 - "$ZMX" "$1" <<'PY'
import os, pty, re, select, sys, time
zmx, step = sys.argv[1], sys.argv[2]
env = dict(os.environ, SHELL="/bin/sh", PS1="$ ")
env.pop("ZMX_SESSION", None)

def drain(fd, seconds):
    out, end = b"", time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    return out.decode(errors="replace")

pid, fd = pty.fork()
if pid == 0:
    os.execvpe(zmx, [zmx, "attach", "outer", "/bin/sh"], env)
drain(fd, 1.5)
if step == "own-pty":
    helper = ("import os,pty,sys,time\n"
              "p,f=pty.fork()\n"
              "if p==0: os.execvp(sys.argv[1],[sys.argv[1],'attach','inner','/bin/sh'])\n"
              "time.sleep(3)\n")
    os.write(fd, f"(python3 -c \"{helper}\" {zmx} </dev/null >/dev/null 2>&1 &) ; sleep 2\r".encode())
else:
    os.write(fd, f"{zmx} attach inner /bin/sh\r".encode())
drain(fd, 3)
os.write(fd, b"echo SHOWN=[$ZMX_SESSION]\r")
shown = re.findall(r"SHOWN=\[([^\]]*)\]", drain(fd, 1.5))
os.kill(pid, 9)
print(shown[-1] if shown else "")
PY
}

@test "attach: a program on its own terminal does not switch the session's client" {
  run attach_from_inside own-pty
  [ "$status" -eq 0 ]
  [ "$output" = "outer" ]
  wait_for_session inner
}

@test "attach: typed at the session's own shell switches its client" {
  run attach_from_inside typed
  [ "$status" -eq 0 ]
  [ "$output" = "inner" ]
}

# Switching an attached client to another session: `zmx attach <other>` typed
# at the session's own shell (the fork only switches from there, see above).
# pty_attach <hold_seconds> <attach args...>: run `zmx attach <args...>` in a pty
# for hold_seconds, draining its output so the client never blocks on writes.
pty_attach() {
  local hold="$1"
  shift
  python3 - "$ZMX" "$hold" "$@" 3>&- <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

zmx, hold, args = sys.argv[1], float(sys.argv[2]), sys.argv[3:]
env = {k: v for k, v in os.environ.items() if k != "ZMX_SESSION"}
env.update(SHELL="/bin/sh", TERM="xterm-256color")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
proc = subprocess.Popen([zmx, "attach", *args], stdin=slave, stdout=slave, stderr=slave, env=env)
deadline = time.monotonic() + hold
while time.monotonic() < deadline and proc.poll() is None:
    if select.select([master], [], [], 0.05)[0]:
        try:
            os.read(master, 65536)
        except OSError:
            break
if proc.poll() is None:
    proc.kill()
    proc.wait(timeout=5)
PY
}

# switch_client <from> <to>: type `zmx attach <to>` at <from>'s shell, moving
# the client attached to <from> over to <to>; returns once it has left <from>
# and arrived at <to>.
switch_client() {
  "$ZMX" run "$1" -d "$ZMX" attach "$2"
  wait_for_clients "$1" 0
  wait_for_clients "$2" 1
}

@test "switch: existing target keeps its own labels" {
  "$ZMX" run test-sw-keep -d sleep 30
  wait_for_session test-sw-keep

  pty_attach 10 --labels role=scratch test-sw-src env ZMXSWSRC=1 /bin/sh 3>&- &
  wait_for_clients test-sw-src 1

  switch_client test-sw-src test-sw-keep

  run "$ZMX" get test-sw-keep
  [ "$status" -eq 0 ]
  [[ "$output" != *"role=scratch"* ]]

  run "$ZMX" get test-sw-src
  [ "$status" -eq 0 ]
  [[ "$output" == *"role=scratch"* ]]

  kill %1 2>/dev/null || true
}

@test "switch: new target gets neither the client's labels nor its command" {
  pty_attach 10 --labels role=scratch test-sw-src2 env ZMXSWSRC=1 /bin/sh 3>&- &
  wait_for_clients test-sw-src2 1

  switch_client test-sw-src2 test-sw-new

  run "$ZMX" list
  [ "$status" -eq 0 ]
  local line
  line=$(grep -F "name=test-sw-new"$'\t' <<<"$output")
  [[ "$line" != *"role=scratch"* ]]
  [[ "$line" != *"ZMXSWSRC"* ]]

  kill %1 2>/dev/null || true
}
