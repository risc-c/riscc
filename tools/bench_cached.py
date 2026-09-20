#!/usr/bin/env python3
"""Compare direct split SRAM with the cache hierarchy, starting with empty caches."""
import argparse
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--xlen', type=int, choices=(16, 32))
    parser.add_argument('--memory', choices=('agilex', 'ecp5-block', 'all'), default='all')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    build = root / 'build/split-cache/bench'
    build.mkdir(parents=True, exist_ok=True)
    results = []
    memories = ('agilex', 'ecp5-block') if args.memory == 'all' else (args.memory,)
    for xlen in ((args.xlen,) if args.xlen else (16, 32)):
        binary = root / ('build/bin/bench.bin' if xlen == 16 else 'build/bin/bench-rc32.bin')
        data = binary.read_bytes()
        image = build / f'bench{xlen}.memh'
        image.write_text(''.join(f'{int.from_bytes(data[n:n+2], "little"):04x}\n'
                                 for n in range(0, len(data), 2)))
        for memory in memories:
            for soft in (False, True):
                for cached in (False, True):
                    multiplier = 'soft' if soft else 'dsp'
                    name = f'{xlen}-{multiplier}-{memory}-{"cache" if cached else "direct"}'
                    out = build / name
                    out.mkdir(exist_ok=True)
                    command = [args.verilator, '--binary', '--timing', '--top-module',
                               'riscc_cached_bench_tb', f'-GXLEN={xlen}', f'-GCACHED={int(cached)}',
                               '--Mdir', str(out), '-j', '4']
                    if soft:
                        command.append('-DRISCC_FAST_SOFT_MUL')
                    if memory == 'ecp5-block':
                        command.append('-DRISCC_FAST_BLOCK_RF')
                    command += [str(root / source) for source in (
                        'rtl/riscc_fast.v', 'rtl/riscc_cached.v',
                        'test/riscc_cached_bench_tb.v')]
                    with (out / 'build.log').open('w') as log:
                        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
                    run = subprocess.run([str(out / 'Vriscc_cached_bench_tb'), f'+IMAGE={image}'],
                                         capture_output=True, text=True, check=True, timeout=30)
                    (out / 'run.log').write_text(run.stdout)
                    line = run.stdout.splitlines()[0]
                    if not line.startswith('PASS '):
                        raise RuntimeError(run.stdout)
                    values = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
                    results.append(dict(xlen=xlen, multiplier=multiplier, memory=memory,
                                        cached=cached, cycles=values['cycles'],
                                        backing_reads=values['backing_reads'],
                                        backing_writes=values['backing_writes']))
                    print(name, line, flush=True)
    (build / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
