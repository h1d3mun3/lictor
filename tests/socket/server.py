#!/usr/bin/env python3
"""Fake LocalAPI server used by the UnixSocketHTTP tests.

Speaks just enough HTTP/1.1 over a unix socket to mimic tailscaled's observed
behaviour (Host validation from docs/localapi.md section 2, 404s from section 3).

    python3 server.py <socket-dir> <number-of-connections-to-serve> [framing]

framing is "length" (default), "chunked" or "eof", matching the three ways a
Go HTTP server can frame a response, or "slam" to accept and close without
reading -- which is what raises SIGPIPE in a client that has not suppressed it.

The socket is created at <socket-dir>/ts.sock. We chdir and bind a relative
path to stay under the AF_UNIX path length limit (104 bytes).
"""
import os
import socket
import sys

sock_dir = sys.argv[1]
expected = int(sys.argv[2])
framing = sys.argv[3] if len(sys.argv) > 3 else "length"

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
        f"Connection: close\r\n"
    )

    if framing == "chunked":
        # How Go frames any handler that writes past its buffer without setting
        # Content-Length. Split deliberately, so a client that ignores the
        # framing ends up with chunk headers inside the JSON.
        head += "Transfer-Encoding: chunked\r\n\r\n"
        conn.sendall(head.encode())
        half = len(payload) // 2
        for piece in (payload[:half], payload[half:]):
            conn.sendall(f"{len(piece):x}\r\n".encode() + piece + b"\r\n")
        conn.sendall(b"0\r\n\r\n")
        return

    if framing == "eof":
        # No framing header at all: the body ends when the connection does.
        head += "\r\n"
        conn.sendall(head.encode() + payload)
        return

    head += f"Content-Length: {len(payload)}\r\n\r\n"
    conn.sendall(head.encode() + payload)


for _ in range(expected):
    conn, _ = server.accept()

    if framing == "slam":
        # Accept and close without reading a byte. A client that has not set
        # SO_NOSIGPIPE dies of SIGPIPE here instead of throwing.
        conn.close()
        continue

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
