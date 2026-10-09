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
