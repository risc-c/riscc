#!/usr/bin/env python3
"""Fetch the pinned CoreMark sources without overwriting local changes."""
from __future__ import annotations

import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]


def verify(data: bytes, expected: str, name: str) -> None:
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"CoreMark checksum mismatch: {name}")


def fetch_sources(root: Path = ROOT) -> None:
    source = root / "external/coremark"
    manifest = json.loads((source / "UPSTREAM.json").read_text())
    missing = []
    for name, digest in manifest["files"].items():
        if Path(name).name != name:
            raise ValueError(f"invalid CoreMark source name: {name}")
        path = source / name
        if path.is_symlink():
            raise ValueError(f"CoreMark source must not be a symlink: {path}")
        if path.exists():
            verify(path.read_bytes(), digest, str(path))
        else:
            missing.append(name)
    if not missing:
        return

    archive = manifest["archive"]
    cache = root / "build/downloads" / f"coremark-{archive['sha256']}.tar.gz"
    if cache.exists():
        data = cache.read_bytes()
        verify(data, archive["sha256"], str(cache))
    else:
        print(f"Fetching CoreMark {manifest['commit']}", flush=True)
        with urlopen(archive["url"], timeout=60) as response:
            data = response.read()
        verify(data, archive["sha256"], archive["url"])
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(data)

    # Read only named regular files; never extract archive paths or links.
    contents = {}
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for name in missing:
            member = tar.getmember(f"coremark-{manifest['commit']}/{name}")
            if not member.isfile():
                raise ValueError(f"CoreMark archive entry is not a regular file: {name}")
            with tar.extractfile(member) as stream:
                contents[name] = stream.read()
            verify(contents[name], manifest["files"][name], name)
    for name, payload in contents.items():
        # Exclusive creation also protects files created during the download.
        with (source / name).open("xb") as stream:
            stream.write(payload)


if __name__ == "__main__":
    try:
        fetch_sources()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        sys.exit(f"CoreMark fetch failed: {error}")
