#!/usr/bin/env python3
"""Convert a little-endian 16-bit binary image to a memory-init file."""

import argparse


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--depth", type=int,
                    help="pad the image with zero words to this RAM depth")
    ap.add_argument("--format", choices=("memh", "mif"), default="memh",
                    help="output format (default: memh)")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()
    words = (len(data) + 1) // 2
    if args.depth is not None and args.depth < words:
        ap.error(f"--depth {args.depth} is smaller than the {words}-word image")
    image = []
    for i in range(0, len(data), 2):
        lo = data[i]
        hi = data[i + 1] if i + 1 < len(data) else 0
        image.append(lo | (hi << 8))
    if args.depth is not None:
        image.extend([0] * (args.depth - words))

    with open(args.output, "w", encoding="ascii") as f:
        if args.format == "mif":
            f.write("WIDTH=16;\nDEPTH=%d;\n\n" % len(image))
            f.write("ADDRESS_RADIX=UNS;\nDATA_RADIX=HEX;\n\nCONTENT BEGIN\n")
            for address, word in enumerate(image):
                f.write("    %d : %04x;\n" % (address, word))
            f.write("END;\n")
        else:
            for word in image:
                f.write("%04x\n" % word)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
