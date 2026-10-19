#!/usr/bin/env python3
"""Guard CoreMark validation, source integrity and short-run reporting."""
import unittest

from run_coremark import CRCS, SHORT_WARNING, check_sources, parse_output, parse_rtl_output


def output(mode="performance", cycles=123456, iterations=100, hz=100000000):
    short = cycles < 10 * hz
    lines = [
        f"{name if name == 'seedcrc' else '[0]' + name} : 0x{value:04x}"
        for name, value in CRCS[mode].items()
    ]
    lines += [
        "[0]crcfinal : 0x1234",
        f"Iterations : {iterations}",
    ]
    lines += (
        [SHORT_WARNING, "Errors detected"]
        if short
        else ["Correct operation validated. See README.md for run and reporting rules."]
    )
    lines += [
        f"RISCC_COREMARK ticks_hi={cycles >> 32} ticks_lo={cycles & 0xffffffff} "
        f"iterations={iterations} hz={hz} short={int(short)} errors=0"
    ]
    return "\n".join(lines) + "\n"


class CoreMarkTests(unittest.TestCase):
    def test_rtl_configuration(self):
        for cached in (False, True):
            config = f"COREMARK_CONFIG cached={int(cached)} btb_entries=32\n"
            done = f"COREMARK_DONE cached={int(cached)} cycles=123456\n"
            text = config + output() + done
            result = parse_rtl_output(text, "performance", 100, 100000000, cached)
            self.assertEqual(result["btb_entries"], 32)
            for invalid in (
                text.replace("btb_entries=32", "btb_entries=16"),
                text.replace(config, ""), config + text, text.replace(done, ""),
            ):
                with self.assertRaises(ValueError):
                    parse_rtl_output(invalid, "performance", 100, 100000000, cached)
            with self.assertRaises(ValueError):
                parse_rtl_output(text, "performance", 100, 100000000, not cached)

    def test_upstream_sources_unchanged(self):
        self.assertEqual(check_sources()["commit"], "1f483d5b8316753a742cbf5590caf5bd0a4e4777")

    def test_short_runs_have_no_score(self):
        for mode in CRCS:
            result = parse_output(output(mode), mode, 100, 100000000)
            self.assertEqual(result["status"], "PASS")
            self.assertFalse(result["compliant_duration"])
            self.assertNotIn("coremark_per_mhz", result)

    def test_compliant_duration(self):
        result = parse_output(output(cycles=1000000000), "performance", 100, 100000000)
        self.assertTrue(result["compliant_duration"])
        self.assertAlmostEqual(result["coremark_per_mhz"], 0.1)

    def test_64_bit_ticks(self):
        cycles = 2**32 + 123456
        result = parse_output(output(cycles=cycles), "performance", 100, 100000000)
        self.assertEqual(result["timed_cycles"], cycles)

    def test_wrong_or_missing_crc_fails(self):
        for name, value in CRCS["performance"].items():
            with self.subTest(name=name), self.assertRaises(ValueError):
                parse_output(
                    output().replace(f"0x{value:04x}", "0xffff"),
                    "performance",
                    100,
                    100000000,
                )
        with self.assertRaises(ValueError):
            parse_output(
                output().replace("seedcrc", "missing"),
                "performance",
                100,
                100000000,
            )

    def test_other_upstream_errors_fail(self):
        with self.assertRaises(ValueError):
            parse_output(
                output() + "ERROR! list CRC mismatch\n",
                "performance",
                100,
                100000000,
            )

    def test_stopped_or_missing_timer_fails(self):
        for text in (output(cycles=0), output().replace("RISCC_COREMARK", "MISSING")):
            with self.assertRaises(ValueError):
                parse_output(text, "performance", 100, 100000000)

    def test_iteration_clock_and_duration_mismatch_fail(self):
        for text in (
            output(iterations=99),
            output(hz=200000000),
            output().replace(SHORT_WARNING, ""),
            output().replace("errors=0", "errors=1"),
        ):
            with self.assertRaises(ValueError):
                parse_output(text, "performance", 100, 100000000)


if __name__ == "__main__":
    unittest.main()
