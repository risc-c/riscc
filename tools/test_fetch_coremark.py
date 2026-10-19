#!/usr/bin/env python3
"""Exercise pinned downloads and offline reuse without network access."""
import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from fetch_coremark import ROOT, fetch_sources


class FetchCoreMarkTests(unittest.TestCase):
    def setUp(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="coremark-fetch-test-", dir=build)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "external/coremark"
        self.source.mkdir(parents=True)
        self.files = {"core_main.c": b"source\n", "LICENSE.md": b"license\n"}
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tar:
            for name, data in self.files.items():
                info = tarfile.TarInfo(f"coremark-pinned/{name}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        self.archive = archive.getvalue()
        self.manifest = {
            "commit": "pinned",
            "archive": {
                "url": "https://example.invalid/coremark.tar.gz",
                "sha256": hashlib.sha256(self.archive).hexdigest(),
            },
            "files": {
                name: hashlib.sha256(data).hexdigest()
                for name, data in self.files.items()
            },
        }
        self.write_manifest()

    def write_manifest(self):
        (self.source / "UPSTREAM.json").write_text(json.dumps(self.manifest))

    def download(self):
        with patch("fetch_coremark.urlopen", return_value=io.BytesIO(self.archive)) as fetch:
            fetch_sources(self.root)
        fetch.assert_called_once_with(self.manifest["archive"]["url"], timeout=60)

    def test_fresh_download_and_offline_reuse(self):
        self.download()
        for name, data in self.files.items():
            self.assertEqual((self.source / name).read_bytes(), data)
        with patch("fetch_coremark.urlopen", side_effect=AssertionError("network access")):
            fetch_sources(self.root)
            # Missing files can also be recovered from the verified archive cache.
            (self.source / "LICENSE.md").unlink()
            fetch_sources(self.root)
        self.assertEqual((self.source / "LICENSE.md").read_bytes(), self.files["LICENSE.md"])

    def test_modified_source_is_preserved(self):
        path = self.source / "core_main.c"
        path.write_bytes(b"local changes")
        with patch("fetch_coremark.urlopen") as fetch, self.assertRaises(ValueError):
            fetch_sources(self.root)
        fetch.assert_not_called()
        self.assertEqual(path.read_bytes(), b"local changes")

    def test_bad_download_is_not_installed_or_cached(self):
        with patch("fetch_coremark.urlopen", return_value=io.BytesIO(b"corrupt")):
            with self.assertRaises(ValueError):
                fetch_sources(self.root)
        self.assertFalse((self.source / "core_main.c").exists())
        self.assertFalse((self.root / "build/downloads").exists())

    def test_bad_cached_archive_is_rejected(self):
        cache = self.root / "build/downloads"
        cache.mkdir(parents=True)
        (cache / f"coremark-{self.manifest['archive']['sha256']}.tar.gz").write_bytes(b"corrupt")
        with patch("fetch_coremark.urlopen") as fetch, self.assertRaises(ValueError):
            fetch_sources(self.root)
        fetch.assert_not_called()
        self.assertFalse((self.source / "core_main.c").exists())

    def test_file_hash_failure_installs_nothing(self):
        self.manifest["files"]["LICENSE.md"] = "0" * 64
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.download()
        self.assertFalse((self.source / "core_main.c").exists())

    def test_symlink_is_preserved_and_rejected(self):
        path = self.source / "core_main.c"
        path.symlink_to(self.source / "absent")
        with self.assertRaises(ValueError):
            fetch_sources(self.root)
        self.assertTrue(path.is_symlink())

    def test_manifest_path_traversal_is_rejected(self):
        self.manifest["files"]["../outside"] = "0" * 64
        self.write_manifest()
        with patch("fetch_coremark.urlopen") as fetch, self.assertRaises(ValueError):
            fetch_sources(self.root)
        fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
