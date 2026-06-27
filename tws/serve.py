#!/usr/bin/env python3
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    repo_root = Path(__file__).resolve().parents[1]
    target_dir = repo_root / "target"

    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=10922)
    args = parser.parse_args()

    if not target_dir.is_dir():
        raise SystemExit(f"missing target directory: {target_dir}")

    handler = partial(SimpleHTTPRequestHandler, directory=str(target_dir))
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"serving {target_dir} at http://{args.host}:{args.port}/")
    server.serve_forever()


if __name__ == "__main__":
    main()
