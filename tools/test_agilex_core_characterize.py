#!/usr/bin/env python3
"""Check generated characterization constraints without invoking Quartus."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from agilex_core_characterize import CACHED_RECIPES, characterize, write_project


class ProjectConstraintsTests(unittest.TestCase):
    def check_project(self, profile, period, optimization):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            directory = root / profile
            write_project(directory, profile, profile, root, root / "core.v",
                          (), root / "top.v", 2)
            self.assertIn(f"-period {period}",
                          (directory / f"{profile}.sdc").read_text())
            self.assertIn(f'OPTIMIZATION_MODE "{optimization}"',
                          (directory / f"{profile}.qsf").read_text())

    def test_cached_uses_selected_efficiency_recipe(self):
        for profile, (optimization, period) in CACHED_RECIPES.items():
            with self.subTest(profile=profile):
                self.check_project(profile, f"{period:.3f}", optimization)

    def test_other_profiles_keep_existing_constraints(self):
        self.check_project("full", "4.000", "AGGRESSIVE AREA")
        self.check_project("min", "4.000", "HIGH PERFORMANCE EFFORT")

    def test_cached_rejects_result_below_200_mhz(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            spec = ("cached_dsp", "cached_dsp", 16, root / "core.v", (),
                    root / "top.v")
            with patch("agilex_core_characterize.subprocess.run"), \
                    patch("agilex_core_characterize.parse_results",
                          return_value=(500, 199.99)):
                with self.assertRaisesRegex(RuntimeError, "misses the 200 MHz"):
                    characterize(spec, root, root, root / "syn", root / "fit",
                                 root / "sta", 2, False)


if __name__ == "__main__":
    unittest.main()
