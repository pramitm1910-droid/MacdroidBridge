#!/usr/bin/env python3
"""Independent stdlib HTTP client parser over a captured in-memory wire response.

--unchecked-chunks reproduces clients that fail to enforce Content-Length.
It is intentionally NOT an integrity verifier. Always run oracle.py afterwards.
"""
import argparse
import http.client
import io
from pathlib import Path

class CapturedSocket:
    def __init__(self, data): self.data = data
    def makefile(self, *_): return io.BytesIO(self.data)

def receive(data, unchecked=False):
    response = http.client.HTTPResponse(CapturedSocket(data)); response.begin()
    if response.status not in (200, 206): raise ValueError(f'HTTP {response.status}')
    if unchecked:
        chunks = []
        while chunk := response.read(8192): chunks.append(chunk)
        return b''.join(chunks)
    return response.read()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('wire', type=Path)
    parser.add_argument('output', type=Path); parser.add_argument('--unchecked-chunks', action='store_true')
    args = parser.parse_args()
    try: args.output.write_bytes(receive(args.wire.read_bytes(), args.unchecked_chunks))
    except http.client.IncompleteRead as error:
        args.output.write_bytes(error.partial); print(f'INCOMPLETE: {len(error.partial)} bytes retained'); raise SystemExit(2)
