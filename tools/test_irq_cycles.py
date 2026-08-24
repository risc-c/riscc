#!/usr/bin/env python3
"""Assert a held IRQ at every cycle of an interrupt-safe ISA image."""

import argparse
import concurrent.futures
import re
import subprocess
import sys


MARKER_RE = re.compile(r"MARKER cycle=(\d+)")
STALL_RE = re.compile(r"STALL cycle=(\d+)")


def run(command):
    return subprocess.run(command, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tb", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--marker", default="0x7ef0")
    parser.add_argument("--max-cycles", type=int, default=10_000_000)
    parser.add_argument("--mem-stall-seed", type=int)
    parser.add_argument("--stall-seed", action="append", type=int, default=[])
    parser.add_argument("--jobs", type=int, default=1)
    args = parser.parse_args()

    common = [args.tb, args.image, "--max-cycles", str(args.max_cycles)]
    if args.mem_stall_seed is not None:
        common += ["--mem-stall-seed", str(args.mem_stall_seed)]

    baseline = run(common + ["--stop-at-write", args.marker])
    match = MARKER_RE.search(baseline.stdout)
    if baseline.returncode or not match:
        sys.stderr.write("IRQ sweep baseline failed:\n" + baseline.stdout)
        return 1
    last_cycle = int(match.group(1))

    jobs = max(1, args.jobs)

    def sweep(cycles, command, description):
        def inject(cycle):
            result = run(command + ["--irq-at", str(cycle)])
            return cycle, result

        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            for cycle, result in executor.map(inject, cycles):
                if result.returncode:
                    sys.stderr.write("%s failed at cycle %d:\n%s" %
                                     (description, cycle, result.stdout))
                    return False
        return True

    if not sweep(range(last_cycle + 1), common, "IRQ sweep"):
        return 1

    print("IRQ cycle sweep PASS: %s, cycles 0..%d (%d injections)" %
          (args.tb, last_cycle, last_cycle + 1))

    for seed in args.stall_seed:
        stalled = [args.tb, args.image, "--max-cycles", str(args.max_cycles),
                   "--mem-stall-seed", str(seed)]
        report = run(stalled + ["--report-stalls", "--stop-at-write",
                                args.marker])
        if report.returncode or not MARKER_RE.search(report.stdout):
            sys.stderr.write("stalled IRQ baseline failed for seed %d:\n%s" %
                             (seed, report.stdout))
            return 1

        waits = sorted({int(match.group(1))
                        for match in STALL_RE.finditer(report.stdout)})
        edges = {cycle + 1 for index, cycle in enumerate(waits)
                 if index + 1 == len(waits) or waits[index + 1] != cycle + 1}
        targeted = sorted(set(waits) | edges)
        if not targeted:
            sys.stderr.write("stalled IRQ baseline reported no waits for seed %d\n" %
                             seed)
            return 1
        if not sweep(targeted, stalled, "stalled IRQ sweep seed %d" % seed):
            return 1
        print("IRQ stalled-cycle sweep PASS: %s, seed=%d (%d injections)" %
              (args.tb, seed, len(targeted)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
