#!/usr/bin/env python3
"""Fake LocalAPI server used by the UnixSocketHTTP tests.

Speaks just enough HTTP/1.1 over a unix socket to mimic tailscaled's observed
behaviour (Host validation from docs/localapi.md section 2, 404s from section 3).

    python3 server.py <socket-dir> <number-of-connections-to-serve>

The socket is created at <socket-dir>/ts.sock. We chdir and bind a relative
path to stay under the AF_UNIX path length limit (104 bytes).
"""
import os
import socket
import sys

sock_dir = sys.argv[1]
expected = int(sys.argv[2])

os.makedirs(sock_dir, exist_ok=True)
os.chdir(sock_dir)
if os.path.exists("ts.sock"):
    os.unlink("ts.sock")

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind("ts.sock")
server.listen(8)
print("ready", flush=True)


def respond(conn, status, reason, body):
    payload = body.encode()
    head = (
        f"HTTP/1.1 {status} {reason}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\n"
        f"Connection: close\r\n\r\n"
    )
    conn.sendall(head.encode() + payload)


for _ in range(expected):
    conn, _ = server.accept()
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            break
        request += chunk

    text = request.decode("utf-8", "replace")
    first = text.split("\r\n")[0]
    headers = {}
    for line in text.split("\r\n")[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower()] = v

    print(f"REQ {first!r} host={headers.get('host')!r}", flush=True)

    path = first.split(" ")[1] if len(first.split(" ")) > 1 else ""

    if headers.get("host") != "local-tailscaled.sock":
        respond(conn, 403, "Forbidden", '{"error":"invalid host"}')
    elif path == "/localapi/v0/prefs":
        respond(conn, 200, "OK",
                '{"RunSSH": true, "OperatorUser": "tester", "WantRunning": true}')
    elif path == "/localapi/v0/status":
        respond(conn, 200, "OK",
                '{"BackendState": "Running", "Health": []}')
    else:
        respond(conn, 404, "Not Found", "404 page not found\n")

    conn.close()

server.close()
