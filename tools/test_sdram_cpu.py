#!/usr/bin/env python3
"""Run firmware on both real board CPUs, caches, CDC fabric and SDRAM model."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def command(args, log):
    result = subprocess.run(list(map(str, args)), cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    log.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"Command failed: {log}\n{result.stdout[-6000:]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/test-sdram-cpu')
    parser.add_argument('--seeds', type=int, default=1)
    parser.add_argument('--verilator', default='verilator')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    clang = ROOT / 'build/llvm-riscc/bin/clang'
    source = ROOT / 'boards/shared/test/sdram'
    flags = ['--target=riscc-none-elf', '-mcpu=full', '-mrc32', '-Os', '-ffreestanding', '-fno-builtin']
    for name in ('simulation_test.c', 'cpu_start.S'):
        command([clang, *flags, '-c', source / name, '-o', build / (name + '.o')], build / (name + '.log'))
    command([clang, *flags, '-nostdlib', '-fuse-ld=lld', '-Wl,-T,' + str(source / 'cpu_link.ld'),
             build / 'cpu_start.S.o', build / 'simulation_test.c.o', '-o', build / 'test.elf'], build / 'link.log')
    command([ROOT / 'build/llvm-riscc/bin/llvm-objcopy', '-O', 'binary', build / 'test.elf', build / 'test.bin'], build / 'objcopy.log')
    binary = (build / 'test.bin').read_bytes()
    binary += bytes((-len(binary)) % 4)
    (build / 'test.memh').write_text(''.join(f'{int.from_bytes(binary[i:i+4], "little"):08x}\n' for i in range(0, len(binary), 4)))
    for board, width, led, period in [('icepi_zero', 16, 5, 15),
                                      ('atum_a3_nano', 32, 4, 5),
                                      ('atum_a3_nano', 32, 4, 7)]:
        name = board + ('-async' if period == 7 else '')
        output = build / name
        output.mkdir(exist_ok=True)
        sources = [source / 'cpu_memory_tb.v', ROOT / f'boards/{board}/rtl/{board}_soc.v',
                   ROOT / 'rtl/riscc_cached.v', ROOT / 'rtl/riscc_fast.v', ROOT / 'test/riscc_sdram_model.v']
        sources += [ROOT / f'boards/shared/rtl/riscc_{name}.v' for name in
                    ('uart_mmio','timer_mmio','irq_ctrl','sdram','sdram_fabric','sdram_bridge')]
        rf_defines = ['-DRISCC_ECP5'] if board == 'icepi_zero' else ['-DRISCC_FAST_BLOCK_RF']
        command([args.verilator, '--binary', '--timing', '-j', '4', '-Wno-UNOPTFLAT',
                 '--top-module', 'cpu_memory_tb', '--Mdir', output,
                 *rf_defines, f'-DSOC_NAME={board}_soc', f'-DLED_BITS={led}',
                 f'-DFIRMWARE="{build / "test.memh"}"', f'-GDATA_BITS={width}', f'-GCPU_PERIOD={period}',
                 *sources], output / 'build.log')
        for seed in range(1, args.seeds + 1):
            result = command([output / 'Vcpu_memory_tb', f'+SEED={seed}'], output / f'run-{seed}.log')
            if result.count('PASS CPU SDRAM') != 2:
                raise RuntimeError('missing reset repeat: ' + result)
            print(f'{name} seed {seed}: ' + ' | '.join(
                line for line in result.splitlines() if line.startswith('PASS CPU SDRAM')))


if __name__ == '__main__':
    main()
