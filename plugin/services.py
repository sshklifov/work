#!/usr/bin/env python3
"""systemd service monitor for work.vim.

Prints "<unit>\t<ActiveState>" for every given unit on startup, then again
whenever one of them changes, by following systemd's PropertiesChanged signals
with dbus-monitor over SSH. Runs until killed.
"""

import re
import subprocess
import sys

MATCH = (
    "type='signal',interface='org.freedesktop.DBus.Properties',"
    "member='PropertiesChanged',arg0='org.freedesktop.systemd1.Unit'"
)


def unit_name(path):
    # Bus paths escape every non-alphanumeric byte as _xx.
    name = path.rsplit("/", 1)[-1]
    return re.sub(r"_([0-9a-f]{2})", lambda m: chr(int(m.group(1), 16)), name)


def report(unit, state):
    print("%s\t%s" % (unit, state), flush=True)


def main():
    host, units = sys.argv[1], sys.argv[2:]

    # Monitor first, so no change between the snapshot and the monitor is lost.
    mon = subprocess.Popen(
        ["ssh", host, 'dbus-monitor --system "%s"' % MATCH],
        stdout=subprocess.PIPE, text=True,
    )
    if not mon.stdout.readline():
        sys.exit("dbus-monitor failed on " + host)

    r = subprocess.run(
        ["ssh", host, "systemctl is-active " + " ".join(units)],
        capture_output=True, text=True,
    )
    snapshot = r.stdout.split()
    if len(snapshot) != len(units):
        mon.kill()
        sys.exit("Unknown state of some services!")
    states = dict(zip(units, snapshot))
    for unit, state in states.items():
        report(unit, state)

    unit = None
    state_next = False
    for line in mon.stdout:
        path = re.search(r"path=(/org/freedesktop/systemd1/unit/[^;]*)", line)
        if path:
            unit = unit_name(path.group(1))
        elif 'string "ActiveState"' in line:
            state_next = True
        elif state_next:
            state_next = False
            state = re.search(r'string "([^"]+)"', line)
            if state and unit in states and states[unit] != state.group(1):
                states[unit] = state.group(1)
                report(unit, states[unit])
    sys.exit("dbus-monitor exited")


if __name__ == "__main__":
    main()
