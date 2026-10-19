#!/usr/bin/env python3
"""Check division-helper GC and transfers between widely separated sections.

Arithmetic, ABI preservation and zero divisors are covered by the RC16 feature
and RC32 division execution tests. This test exercises the actual runtime
assembly with different roots, optimization policies and linker placements.
"""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--llvm-bin", type=Path, default=ROOT / "build/llvm-riscc/bin"
    )
    args = parser.parse_args()
    # Do not resolve ld.lld itself: its driver selection depends on argv[0].
    tools = args.llvm_bin.absolute()
    (ROOT / "build").mkdir(exist_ok=True)
    checks = 0

    def run(*command: object) -> str:
        return subprocess.check_output(
            [str(arg) for arg in command],
            text=True,
            stderr=subprocess.STDOUT,
        )

    with tempfile.TemporaryDirectory(
        prefix="runtime-sections-", dir=ROOT / "build"
    ) as temp:
        work = Path(temp)
        for width, profiles in (
            (16, ("nano", "min", "sys", "full")),
            (32, ("min", "sys", "full")),
        ):
            sources = ("div",) if width == 16 else ("integer", "wide_div")
            for profile in profiles:
                objects: dict[str, list[Path]] = {}
                for opt in ("O2", "Os", "Oz"):
                    objects[opt] = []
                    for source in sources:
                        obj = work / f"rc{width}-{profile}-{opt}-{source}.o"
                        run(
                            tools / "clang",
                            "--target=riscc-none-elf",
                            f"-mcpu={profile}",
                            *(["-mrc32"] if width == 32 else []),
                            f"-{opt}",
                            "-c",
                            ROOT / f"firmware/rc{width}/{source}.S",
                            "-o",
                            obj,
                        )
                        objects[opt].append(obj)

                if profile in ("min", "nano"):
                    # These profiles have no direct long transfer. Their
                    # compact entry paths must not acquire a full-range thunk.
                    for opt in ("Os", "Oz"):
                        for old, new in zip(objects["O2"], objects[opt]):
                            assert old.read_bytes() == new.read_bytes(), (old, new)
                    continue

                def link(
                    opt: str,
                    entry: str,
                    *,
                    script: Path | None = None,
                    relax: bool = True,
                ) -> tuple[set[str], str, int]:
                    nonlocal checks
                    elf = work / f"rc{width}-{profile}-{opt}-{entry}.elf"
                    run(
                        tools / "ld.lld",
                        "--gc-sections",
                        "--emit-relocs",
                        "--relax" if relax else "--no-relax",
                        "-e",
                        entry,
                        *(["-T", script] if script else ["-Ttext=0x100"]),
                        *objects[opt],
                        "-o",
                        elf,
                    )
                    symbols = {
                        line.split()[0]
                        for line in run(
                            tools / "llvm-nm",
                            "--defined-only",
                            "--format=posix",
                            elf,
                        ).splitlines()
                    }
                    relocations = run(tools / "llvm-readobj", "--relocations", elf)
                    # Berkeley text size excludes holes between far output sections.
                    text_size = int(
                        run(tools / "llvm-size", elf).splitlines()[1].split()[0]
                    )
                    checks += 1
                    return symbols, relocations, text_size

                unsigned_roots = (
                    "__udivsi3",
                    "__udivmodsi4",
                    "__udivdi3",
                    "__udivmoddi4",
                )
                for entry in unsigned_roots:
                    _, _, grouped_size = link("O2", entry)
                    for opt in ("Os", "Oz"):
                        symbols, _, size = link(opt, entry)
                        assert entry in symbols, (width, profile, opt, entry)
                        if width == 32:
                            assert not symbols & {
                                "__divsi3",
                                "__modsi3",
                                "__divmodsi4",
                                "__divdi3",
                                "__moddi3",
                                "__divmoddi4",
                            }, symbols
                        else:
                            suffix = "si3" if entry.endswith(("si3", "si4")) else "di3"
                            assert "__umod" + suffix not in symbols, symbols
                            if "mod" in entry:
                                assert "__udiv" + suffix not in symbols, symbols
                        assert size < grouped_size, (
                            width,
                            profile,
                            opt,
                            entry,
                            size,
                            grouped_size,
                        )

                # A custom script may separate independently collected sections
                # arbitrarily. Test beyond compact range, and beyond RC32 JALL's
                # 2 MiB absolute range, both with and without relaxation.
                if width == 32:
                    far = work / "far32.ld"
                    far.write_text(
                        "SECTIONS {\n"
                        " .signed 0x100 : { *(.text.__divmodsi4) *(.text.__divmoddi4) }\n"
                        " .unsigned 0x210000 : { *(.text.__udivmodsi4) *(.text.__udivmoddi4) }\n"
                        " /DISCARD/ : { *(.comment) *(.note.GNU-stack) }\n}\n"
                    )
                    roots = (
                        "__divsi3",
                        "__modsi3",
                        "__divmodsi4",
                        "__divdi3",
                        "__moddi3",
                        "__divmoddi4",
                    )
                else:
                    far = work / "far16.ld"
                    far.write_text(
                        "SECTIONS {\n"
                        " .wrappers 0x100 : { *(.text.__udivsi3) *(.text.__umodsi3)"
                        " *(.text.__udivdi3) *(.text.__umoddi3) }\n"
                        " .cores 0x6000 : { *(.text.__udivmodsi4) *(.text.__udivmoddi4) }\n"
                        " /DISCARD/ : { *(.comment) *(.note.GNU-stack) }\n}\n"
                    )
                    roots = (
                        "__udivsi3",
                        "__umodsi3",
                        "__udivdi3",
                        "__umoddi3",
                    )
                for entry in roots:
                    for relax in (False, True):
                        symbols, relocations, _ = link("Os", entry, script=far, relax=relax)
                        assert entry in symbols
                        if width == 32 and profile != "min":
                            # Out-of-range targets must retain full-width literals.
                            assert "R_RISCC_CALL_TARGET" in relocations, relocations
                            assert "R_RISCC_JALL21" not in relocations, relocations
    print(f"runtime sections: {checks} GC/range links passed; Min/Nano objects unchanged")


if __name__ == "__main__":
    main()
