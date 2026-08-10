#!/usr/bin/env python3
"""RTSP stream discovery for work.vim.

Scans the noauth (8554) and authenticated (554) RTSP services on a device,
performs Digest auth for 554 (credentials fetched from redis over SSH), issues
a DESCRIBE for each known stream and prints, per discovered stream, a line of

    <LABEL>\t<gst-launch command>

where LABEL is "<TYPE> <PORT>: <name>". With --debug it dumps the raw RTSP
responses instead. Hard errors are printed to stdout and exit non-zero so the
Vim side can surface them.
"""

import argparse
import hashlib
import re
import shlex
import socket
import subprocess
import sys

PORTS = [8554, 554]  # 8554 = noauth, 554 = Digest auth

STREAMS = {
    "onyx": ["ircamera", "mircamera", "depthcamera", "mdepthcamera", "rgbcamera", "mrgbcamera"],
    "rockx": ["adaptive_h264", "adaptive_mjpeg", "near-rtsp", "far-rtsp", "center-rtsp", "intercom"],
}


def die(msg):
    print(msg)
    sys.exit(1)


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def device_streams(device):
    for key, streams in STREAMS.items():
        if key in device:
            return streams
    die("Unknown device: " + device)


def port_open(ip, port):
    try:
        with socket.create_connection((ip, port), timeout=1):
            return True
    except OSError:
        return False


def ssh_check(host):
    """Dies unless an SSH connection to host can be established."""
    r = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=1", host, "true"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        die("SSH to %s failed: %s" % (host, r.stderr.strip() or "unreachable"))


def rtsp_exchange(ip, port, payload, timeout=3.0):
    """Send payload over a fresh connection and return the full text response."""
    chunks = []
    with socket.create_connection((ip, port), timeout=timeout) as s:
        s.sendall(payload.encode())
        s.settimeout(timeout)
        try:
            while True:
                data = s.recv(4096)
                if not data:
                    break
                chunks.append(data)
        except socket.timeout:
            pass
    return b"".join(chunks).decode(errors="replace")


def fetch_device_type(host):
    """Returns the device type from /var/lib/mender/device_type over SSH."""
    r = subprocess.run(
        ["ssh", host, "cat /var/lib/mender/device_type"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        die("Could not read device type: %s" % (r.stderr.strip() or "failed"))
    # File format: device_type=<value>
    return r.stdout.strip().split("=", 1)[-1]


def fetch_credentials(host):
    """Returns (user, password) of the first ONVIF user from redis over SSH."""
    lua = (
        "local u=redis.call([[SMEMBERS]],[[onvif.users.User]]) "
        "for _,h in ipairs(u) do "
        "local n=redis.call([[HGET]],h,[[userName]]) "
        "local p=redis.call([[HGET]],h,[[password]]) "
        "if n and p then return n..string.char(9)..p end "
        "end "
        "return [[]]"
    )
    remote = "redis-cli -n 1 -s /run/redis/redis.sock EVAL '%s' 0" % lua
    r = subprocess.run(["ssh", host, remote], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "redis fetch failed")
    line = r.stdout.strip()
    if "\t" not in line:
        raise RuntimeError("No RTSP credentials found")
    user, pw = line.split("\t", 1)
    return user, pw


def build_batch(ip, port, streams, auth=None):
    """Builds a DESCRIBE request for every stream, optionally Digest-signed."""
    parts = []
    for seq, stream in enumerate(streams, start=2):
        uri = "rtsp://%s:%d/%s" % (ip, port, stream)
        header = ""
        if auth:
            ha2 = md5("DESCRIBE:" + uri)
            resp = md5("%s:%s:%s" % (auth["ha1"], auth["nonce"], ha2))
            header = (
                'Authorization: Digest username="%s", realm="%s", nonce="%s", '
                'uri="%s", response="%s"\r\n'
                % (auth["user"], auth["realm"], auth["nonce"], uri, resp)
            )
        parts.append(
            "DESCRIBE %s RTSP/1.0\r\nCSeq: %d\r\n%sAccept: application/sdp\r\n\r\n"
            % (uri, seq, header)
        )
    return "".join(parts)


def collect(ip, port, streams, host):
    """Returns (found, raw) for one port. found is a list of (type, name, creds);
    creds is (user, pw) for 554 or None. Raises RuntimeError on failure."""
    opts = rtsp_exchange(ip, port, "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\n\r\n", timeout=1)
    if "DESCRIBE" not in opts:
        return [], ""

    auth = None
    creds = None
    if port == 554:
        user, pw = fetch_credentials(host)
        creds = (user, pw)
        # Unauthenticated batch first, to obtain the Digest challenge.
        chal = rtsp_exchange(ip, port, build_batch(ip, port, streams))
        realm = re.search(r'realm="([^"]*)"', chal)
        nonce = re.search(r'nonce="([^"]*)"', chal)
        if not nonce:
            raise RuntimeError("No Digest challenge received")
        auth = {
            "user": user,
            "realm": realm.group(1) if realm else "",
            "nonce": nonce.group(1),
            "ha1": md5("%s:%s:%s" % (user, realm.group(1) if realm else "", pw)),
        }

    raw = rtsp_exchange(ip, port, build_batch(ip, port, streams, auth))

    # Split into individual RTSP responses and parse each on its own, so a
    # stream with extra/missing SDP lines can't desync the rest of the batch.
    found = []
    for block in re.split(r"(?=RTSP/[0-9.]+ \d)", raw):
        if "200 OK" not in block:
            continue
        cb = re.search(r"^Content-Base:\s*(\S+)", block, re.M)
        rm = re.search(r"^a=rtpmap:\S+\s+(\S+)", block, re.M)
        if not cb or not rm:
            continue
        name = cb.group(1).rstrip("/").rsplit("/", 1)[-1]
        codec = rm.group(1).upper()
        if "H264" in codec:
            found.append(("H264", name, creds))
        elif "JPEG" in codec:
            found.append(("MJPEG", name, creds))
    return found, raw


def gst_command(type_, ip, port, name, creds):
    if type_ == "H264":
        pipe = "latency=100 ! rtph264depay ! h264parse ! avdec_h264 ! fpsdisplaysink video-sink=autovideosink"
    else:
        pipe = "latency=0 ! rtpjpegdepay ! jpegparse ! avdec_mjpeg ! fpsdisplaysink video-sink=autovideosink"
    auth = ""
    if creds:
        auth = " user-id=%s user-pw=%s" % (shlex.quote(creds[0]), shlex.quote(creds[1]))
    return "gst-launch-1.0 rtspsrc location=rtsp://%s:%d/%s%s %s" % (ip, port, name, auth, pipe)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ip")
    ap.add_argument("--host", help="SSH target for redis (default: root@<ip>)")
    ap.add_argument("--device", help="device type (default: read from device over SSH)")
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args()

    host = args.host or "root@" + args.ip
    ssh_check(host)

    device = args.device or fetch_device_type(host)
    streams = device_streams(device)

    open_ports = [p for p in PORTS if port_open(args.ip, p)]
    if not open_ports:
        die("Neither 8554 nor 554 port are open!")

    all_found = []
    raw_all = []
    errors = []
    for port in open_ports:
        try:
            found, raw = collect(args.ip, port, streams, host)
        except (RuntimeError, OSError) as e:
            errors.append("port %d: %s" % (port, e))
            continue
        for type_, name, creds in found:
            all_found.append((type_, port, name, creds))
        if raw:
            raw_all.append("===== port %d =====" % port)
            raw_all.extend(raw.split("\r\n"))

    if args.debug:
        print("Open ports: " + ", ".join(str(p) for p in open_ports))
        print("\n".join(raw_all))
        if errors:
            print("\n===== errors =====")
            print("\n".join(errors))
        return

    if not all_found and errors:
        die("; ".join(errors))

    for type_, port, name, creds in all_found:
        label = "%s%s: %s" % (type_, " Secure" if port == 554 else "", name)
        print("%s\t%s" % (label, gst_command(type_, args.ip, port, name, creds)))


if __name__ == "__main__":
    main()
