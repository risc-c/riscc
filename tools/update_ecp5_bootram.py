#!/usr/bin/env python3
"""Replace the 16 KiB boot SRAM in an already placed ECP5 config."""

import argparse
import re
from pathlib import Path


WORDS = 4096
LANES = 8
BANK_WORDS = WORDS // 2
ROWS = BANK_WORDS // 8
WORD = r"[0-9a-fA-F]{3}"
BLOCK = re.compile(
    rf"(?m)^\.bram_init[ \t]+(?P<id>\S+)[ \t]*\n"
    rf"(?P<data>(?:{WORD}(?:[ \t]+{WORD}){{7}}\n){{{ROWS}}})"
)
HEADER = re.compile(r"(?m)^\.bram_init[ \t]+\S+[ \t]*$")
IMAGE_WORD = re.compile(r"[0-9a-fA-F]{8}\Z")


def error(message):
    raise ValueError(message)


def image(path):
    try:
        lines = path.read_bytes().decode("ascii").splitlines()
    except (OSError, UnicodeError) as exc:
        error(f"cannot read {path}: {exc}")
    if len(lines) != WORDS:
        error(f"{path}: expected {WORDS} 32-bit words, found {len(lines)}")
    if any(IMAGE_WORD.fullmatch(line) is None for line in lines):
        bad = next(i for i, line in enumerate(lines, 1) if IMAGE_WORD.fullmatch(line) is None)
        error(f"{path}:{bad}: expected exactly eight hexadecimal digits")
    return tuple(int(line, 16) for line in lines)


def banks(words):
    """Pack neighboring physical 4-bit words into each config bank word's bits 7:0."""
    return tuple(
        tuple(
            ((words[2 * address] >> (4 * lane)) & 0xF)
            | (((words[2 * address + 1] >> (4 * lane)) & 0xF) << 4)
            for address in range(BANK_WORDS)
        )
        for lane in range(LANES)
    )


def config_blocks(path):
    try:
        text = path.read_bytes().decode("ascii")
    except (OSError, UnicodeError) as exc:
        error(f"cannot read {path}: {exc}")
    if "\r" in text:
        error(f"{path}: expected the generated LF-only config format")
    headers = list(HEADER.finditer(text))
    matches = list(BLOCK.finditer(text))
    if {match.start() for match in headers} != {match.start() for match in matches}:
        error(f"{path}: malformed or truncated .bram_init block")
    blocks = []
    ids = set()
    for match in matches:
        ident = match.group("id")
        if ident in ids:
            error(f"{path}: duplicate .bram_init ID {ident}")
        ids.add(ident)
        values = tuple(int(word, 16) for word in match.group("data").split())
        if len(values) != BANK_WORDS or any(value > 0x1FF for value in values):
            error(f"{path}: .bram_init {ident} has invalid bank geometry or width")
        blocks.append((ident, match.start("data"), match.end("data"), values))
    if len(blocks) < LANES:
        error(f"{path}: found {len(blocks)} .bram_init blocks, expected at least {LANES}")
    return text, blocks


def replacement(values):
    return "".join(
        " ".join(f"{value:03x}" for value in values[offset : offset + 8]) + "\n"
        for offset in range(0, BANK_WORDS, 8)
    )


def update(input_path, output_path, from_path, to_path):
    if input_path.resolve() == output_path.resolve():
        error("input and output config paths must be distinct")
    if from_path.resolve() == to_path.resolve():
        error("--from-hex and --to-hex paths must be distinct")
    if not output_path.parent.is_dir():
        error(f"output directory does not exist: {output_path.parent}")

    old = banks(image(from_path))
    new = banks(image(to_path))
    config, blocks = config_blocks(input_path)
    selected = []
    for lane, bank in enumerate(old):
        found = [index for index, block in enumerate(blocks) if block[3] == bank]
        if len(found) != 1:
            ids = ", ".join(blocks[index][0] for index in found) or "none"
            error(f"lane {lane}: expected one exact full-bank match, found {len(found)} ({ids})")
        selected.append(found[0])
    if len(set(selected)) != LANES:
        error("old image lanes do not map to eight distinct .bram_init blocks")

    for lane, index in sorted(enumerate(selected), key=lambda item: blocks[item[1]][1], reverse=True):
        ident, start, end, _ = blocks[index]
        config = config[:start] + replacement(new[lane]) + config[end:]
    output_path.write_bytes(config.encode("ascii"))
    return [blocks[index][0] for index in selected]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_config", type=Path)
    parser.add_argument("output_config", type=Path)
    parser.add_argument("--from-hex", required=True, type=Path)
    parser.add_argument("--to-hex", required=True, type=Path)
    args = parser.parse_args()
    try:
        selected = update(args.input_config, args.output_config, args.from_hex, args.to_hex)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(f"updated {args.output_config}; matched lane banks {', '.join(selected)}")


if __name__ == "__main__":
    main()
