#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import os
import threading
import struct
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from tools.toolchain import swift_command
ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
sources = [p for p in sorted((ROOT / "Sources").glob("*.swift")) if p.name != "main.swift"]
subprocess.run([*swift_command(), *map(str, sources), str(ROOT / "Tests" / "main.swift"),
                "-o", str(BUILD / "QingmoTests")], check=True)
# Exercise the production URLSession loader against deterministic, loopback-only HTTP.
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\x40\x90\x80\xff")) + chunk(b"IEND", b"")
class ImageHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == "/slow.png":
            import time
            time.sleep(0.5)
        status = 404 if self.path == "/missing.png" else 200
        data = b"invalid image" if self.path == "/invalid.png" else png
        self.send_response(status)
        self.send_header("Content-Length", str(33 * 1024 * 1024 if self.path == "/oversize.png" else len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
server = ThreadingHTTPServer(("127.0.0.1", 0), ImageHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, QINGMO_IMAGE_TEST_URL=f"http://127.0.0.1:{server.server_address[1]}/")
    subprocess.run([str(BUILD / "QingmoTests"), *sys.argv[1:]], check=True, env=env)
finally:
    server.shutdown()
    server.server_close()
