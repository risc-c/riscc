#!/usr/bin/env python3
"""Convert a little-endian binary image to a memory-init file."""

import argparse


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--depth", type=int,
                    help="pad the image with zero words to this RAM depth")
    ap.add_argument("--width", type=int, choices=(16, 32), default=16,
                    help="memory word width in bits (default: 16)")
    ap.add_argument("--format", choices=("memh", "mif"), default="memh",
                    help="output format (default: memh)")
    args = ap.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()
    bytes_per_word = args.width // 8
    words = (len(data) + bytes_per_word - 1) // bytes_per_word
    if args.depth is not None and args.depth < words:
        ap.error(f"--depth {args.depth} is smaller than the {words}-word image")
    image = []
    for i in range(0, len(data), bytes_per_word):
        word = 0
        for byte in range(bytes_per_word):
            if i + byte < len(data):
                word |= data[i + byte] << (byte * 8)
        image.append(word)
    if args.depth is not None:
        image.extend([0] * (args.depth - words))

    with open(args.output, "w", encoding="ascii") as f:
        if args.format == "mif":
            f.write("WIDTH=%d;\nDEPTH=%d;\n\n" % (args.width, len(image)))
            f.write("ADDRESS_RADIX=UNS;\nDATA_RADIX=HEX;\n\nCONTENT BEGIN\n")
            for address, word in enumerate(image):
                f.write("    %d : %0*x;\n" %
                        (address, args.width // 4, word))
            f.write("END;\n")
        else:
            for word in image:
                f.write("%0*x\n" % (args.width // 4, word))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
