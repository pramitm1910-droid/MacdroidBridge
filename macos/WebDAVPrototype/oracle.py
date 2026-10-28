#!/usr/bin/env python3
"""Independent receiver check: never import server byte-generation code."""
import argparse
import hashlib
import json
from pathlib import Path

SIZES = {'integrity.bin':196625, 'empty.bin':0, 'Résumé <&>.txt':257}

def expected(size):
    cycle = bytes(range(251))
    pattern = bytes(cycle[(31*j+7) % len(cycle)] for j in range(251))
    return (pattern * (size // 251 + 1))[:size]

def verify(path, name):
    size = SIZES[name]
    digest = hashlib.sha256(); count = 0
    with open(path, 'rb') as stream:
        while chunk := stream.read(65536): digest.update(chunk); count += len(chunk)
    wanted = hashlib.sha256(expected(size)).hexdigest()
    result = {'file':str(path), 'expected_size':size, 'actual_size':count,
              'expected_sha256':wanted, 'actual_sha256':digest.hexdigest(),
              'verified':count == size and digest.hexdigest() == wanted}
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('file', type=Path)
    parser.add_argument('--fixture', choices=SIZES, default='integrity.bin')
    args = parser.parse_args(); result = verify(args.file, args.fixture)
    print(json.dumps(result, indent=2)); raise SystemExit(0 if result['verified'] else 1)
