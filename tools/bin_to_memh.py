#!/usr/bin/env python3
"""Convert a little-endian 16-bit binary image to Verilog readmemh words."""

import argparse


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--depth", type=int,
                    help="pad the image with zero words to this RAM depth")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()
    words = (len(data) + 1) // 2
    if args.depth is not None and args.depth < words:
        ap.error(f"--depth {args.depth} is smaller than the {words}-word image")
    with open(args.output, "w", encoding="ascii") as f:
        for i in range(0, len(data), 2):
            lo = data[i]
            hi = data[i + 1] if i + 1 < len(data) else 0
            f.write("%04x\n" % (lo | (hi << 8)))
        if args.depth is not None:
            for _ in range(words, args.depth):
                f.write("0000\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
