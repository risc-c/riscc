#!/usr/bin/env python3
"""Assert that the optional IRQ archive pulls only the requested support."""

from __future__ import annotations

import argparse
from pathlib import Path


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"error: cannot read {path}: {exc}") from exc


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"error: {label} is missing {needle!r}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise SystemExit(f"error: {label} unexpectedly contains {needle!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--normal", type=Path, required=True)
    parser.add_argument("--c-wrapper", type=Path, required=True)
    parser.add_argument("--custom", type=Path, required=True)
    args = parser.parse_args()

    normal = read(args.normal)
    require(normal, "libirq.a(irq_default.o)", "normal image")
    forbid(normal, "libirq.a(irq_control.o)", "normal image")
    forbid(normal, "libirq.a(irq.o)", "normal image")
    forbid(normal, ".riscc.irq_context", "normal image")

    c_wrapper = read(args.c_wrapper)
    require(c_wrapper, "libirq.a(irq_control.o)", "C IRQ image")
    require(c_wrapper, "libirq.a(irq.o)", "C IRQ image")
    require(c_wrapper, ".riscc.irq_context", "C IRQ image")
    require(c_wrapper, ".bss.riscc_irq_handler", "C IRQ image")
    require(c_wrapper, ".bss.riscc_irq_stack", "C IRQ image")
    forbid(c_wrapper, "libirq.a(irq_default.o)", "C IRQ image")

    custom = read(args.custom)
    require(custom, "libirq.a(irq_control.o)", "custom-vector image")
    forbid(custom, "libirq.a(irq_default.o)", "custom-vector image")
    forbid(custom, "libirq.a(irq.o)", "custom-vector image")
    forbid(custom, ".riscc.irq_context", "custom-vector image")
    forbid(custom, ".bss.riscc_irq_handler", "custom-vector image")
    forbid(custom, ".bss.riscc_irq_stack", "custom-vector image")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
