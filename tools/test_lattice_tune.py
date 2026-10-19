#!/usr/bin/env python3
"""Tests for timing-constrained mapper selection (no FPGA tools required)."""
import unittest

from lattice_tune import select_timed


def row(recipe, area, mhz):
    return dict(recipe=recipe, block_area=str(area), fmax_mhz=str(mhz), seed="1")


class TimedSelectionTests(unittest.TestCase):
    def test_best_efficiency_above_target(self):
        efficient = row("efficient", 1293, 74)
        rows = [row("small", 1240, 68), efficient, row("fastest", 2000, 80)]
        self.assertIs(select_timed(rows, 66.67), efficient)

    def test_more_efficient_mapping_below_target_is_excluded(self):
        feasible = row("feasible", 1240, 68)
        self.assertIs(select_timed([row("slow", 100, 60), feasible], 66.67),
                      feasible)

    def test_smaller_area_breaks_efficiency_tie(self):
        small = row("small", 100, 70)
        self.assertIs(select_timed([row("large", 200, 140), small], 66.67), small)

    def test_frequency_breaks_area_tie(self):
        fast = row("fast", 1240, 68)
        self.assertIs(select_timed([row("slow", 1240, 67), fast], 66.67), fast)

    def test_exact_target_is_eligible(self):
        exact = row("exact", 100, 66.67)
        self.assertIs(select_timed([exact], 66.67), exact)

    def test_unmet_target_is_not_silently_relaxed(self):
        with self.assertRaisesRegex(RuntimeError, "no successful mapping meets"):
            select_timed([row("slow", 100, 60)], 66.67)

    def test_unconstrained_selection_keeps_efficiency_policy(self):
        efficient = row("efficient", 110, 80)
        self.assertIs(select_timed([row("small", 100, 60), efficient]), efficient)


if __name__ == "__main__":
    unittest.main()
