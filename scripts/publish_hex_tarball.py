#!/usr/bin/env python3
"""Publish one already-built Hex tarball exactly, with idempotent verification."""

from __future__ import annotations

import argparse
import os
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any


PACKAGE = re.compile(r"^[a-z][a-z0-9_]*$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")


def validate_identity(tarball: Path, package: str, version: str) -> bytes:
    """Read a Hex tarball and prove its declared package identity."""
    if not PACKAGE.fullmatch(package):
        raise RuntimeError(f"invalid Hex package name: {package!r}")
    if not VERSION.fullmatch(version):
        raise RuntimeError(f"invalid Hex package version: {version!r}")
    try:
        payload = tarball.read_bytes()
        with tarfile.open(tarball, mode="r:") as archive:
            member = archive.getmember("metadata.config")
            stream = archive.extractfile(member)
            metadata = stream.read() if stream is not None else b""
    except (OSError, KeyError, tarfile.TarError) as error:
        raise RuntimeError(f"could not read Hex tarball {tarball}: {error}") from error
    declarations = (
        (b'{<<"name">>, <<"' + package.encode() + b'"/utf8>>}.'),
        (b'{<<"version">>, <<"' + version.encode() + b'"/utf8>>}.'),
    )
    if any(declaration not in metadata for declaration in declarations):
        raise RuntimeError(
            f"Hex tarball metadata does not declare {package} {version}"
        )
    return payload


def request(
    url: str,
    *,
    method: str,
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    opener: Callable[..., Any] = urllib.request.urlopen,
) -> tuple[int, bytes]:
    value = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method=method,
    )
    try:
        with opener(value, timeout=30) as response:
            return int(response.status), response.read()
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.read()
        finally:
            error.close()
    except urllib.error.URLError as error:
        raise RuntimeError(f"Hex request failed: {error.reason}") from error


def require_exact(remote: bytes, expected: bytes, version: str) -> None:
    if remote != expected:
        raise RuntimeError(
            f"Hex already contains different bytes for kangaroo {version}"
        )


def publish(
    tarball: Path,
    package: str,
    version: str,
    *,
    api_key: str | None,
    opener: Callable[..., Any] = urllib.request.urlopen,
    sleeper: Callable[[float], None] = time.sleep,
    attempts: int = 12,
    delay_seconds: float = 5,
    api_root: str = "https://hex.pm/api",
    repository_root: str = "https://repo.hex.pm",
) -> str:
    """Publish once, or prove that the exact bytes are already published."""
    if attempts < 1 or delay_seconds < 0:
        raise ValueError("poll attempts must be positive and delay non-negative")
    payload = validate_identity(tarball, package, version)
    escaped_package = urllib.parse.quote(package, safe="")
    escaped_filename = urllib.parse.quote(f"{package}-{version}.tar", safe="")
    download_url = f"{repository_root}/tarballs/{escaped_filename}"
    status, remote = request(download_url, method="GET", opener=opener)
    if status == 200:
        require_exact(remote, payload, version)
        return "already-published"
    if status != 404:
        raise RuntimeError(f"Hex tarball lookup returned HTTP {status}")
    if not api_key:
        raise RuntimeError("HEXPM_API_KEY is required to publish a new release")

    publish_url = (
        f"{api_root}/packages/{escaped_package}/releases?replace=false"
    )
    status, response = request(
        publish_url,
        method="POST",
        data=payload,
        headers={
            "Accept": "application/json",
            "Authorization": api_key,
            "Content-Type": "application/octet-stream",
            "User-Agent": f"kangaroo-release/{version}",
        },
        opener=opener,
    )
    if status not in (200, 201, 409, 422):
        detail = response.decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"Hex publish returned HTTP {status}: {detail or '<empty response>'}"
        )

    for attempt in range(attempts):
        lookup_status, remote = request(download_url, method="GET", opener=opener)
        if lookup_status == 200:
            require_exact(remote, payload, version)
            return "published" if status in (200, 201) else "already-published"
        if lookup_status != 404:
            raise RuntimeError(
                f"Hex post-publish lookup returned HTTP {lookup_status}"
            )
        if attempt + 1 < attempts:
            sleeper(delay_seconds)
    detail = response.decode("utf-8", errors="replace").strip()
    if status in (409, 422):
        raise RuntimeError(
            f"Hex publish returned HTTP {status}: {detail or '<empty response>'}"
        )
    raise RuntimeError(
        "Hex accepted the publish request but the exact tarball did not become "
        f"available: {detail or '<empty response>'}"
    )


def parse_args(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tarball", type=Path)
    parser.add_argument("package")
    parser.add_argument("version")
    return parser.parse_args(arguments)


def main(arguments: Sequence[str] | None = None) -> int:
    options = parse_args(arguments)
    result = publish(
        options.tarball.resolve(),
        options.package,
        options.version,
        api_key=os.environ.get("HEXPM_API_KEY"),
    )
    print(f"Hex {result}: {options.package} {options.version}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"Hex publication failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
