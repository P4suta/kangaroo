#!/usr/bin/env python3
"""Unit tests for exact, idempotent Hex tarball publication."""

from __future__ import annotations

import io
import sys
import tarfile
import tempfile
import unittest
import urllib.error
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parent))

import publish_hex_tarball  # noqa: E402


class Response:
    def __init__(self, status: int, body: bytes = b"") -> None:
        self.status = status
        self.body = body

    def __enter__(self) -> "Response":
        return self

    def __exit__(self, *_arguments: object) -> None:
        return None

    def read(self) -> bytes:
        return self.body


def fixture_tarball(path: Path, package: str = "kangaroo", version: str = "1.0.0") -> bytes:
    metadata = (
        f'{{<<"name">>, <<"{package}"/utf8>>}}.\n'
        f'{{<<"version">>, <<"{version}"/utf8>>}}.\n'
    ).encode()
    with tarfile.open(path, mode="w") as archive:
        member = tarfile.TarInfo("metadata.config")
        member.size = len(metadata)
        archive.addfile(member, io.BytesIO(metadata))
    return path.read_bytes()


class PublishHexTarballTest(unittest.TestCase):
    def test_existing_exact_release_is_a_success_without_a_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tarball = Path(directory) / "kangaroo-1.0.0.tar"
            payload = fixture_tarball(tarball)
            methods: list[str] = []

            def opener(request: object, **_options: object) -> Response:
                methods.append(request.get_method())  # type: ignore[attr-defined]
                return Response(200, payload)

            result = publish_hex_tarball.publish(
                tarball, "kangaroo", "1.0.0", api_key=None, opener=opener
            )
            self.assertEqual(result, "already-published")
            self.assertEqual(methods, ["GET"])

    def test_existing_different_release_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tarball = Path(directory) / "kangaroo-1.0.0.tar"
            fixture_tarball(tarball)
            with self.assertRaisesRegex(RuntimeError, "different bytes"):
                publish_hex_tarball.publish(
                    tarball,
                    "kangaroo",
                    "1.0.0",
                    api_key=None,
                    opener=lambda *_args, **_kwargs: Response(200, b"different"),
                )

    def test_missing_release_publishes_the_exact_payload_then_verifies_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tarball = Path(directory) / "kangaroo-1.0.0.tar"
            payload = fixture_tarball(tarball)
            calls: list[object] = []
            responses = iter([
                urllib.error.HTTPError("url", 404, "missing", {}, io.BytesIO()),
                Response(201, b'{"version":"1.0.0"}'),
                urllib.error.HTTPError("url", 404, "pending", {}, io.BytesIO()),
                Response(200, payload),
            ])

            def opener(request: object, **_options: object) -> object:
                calls.append(request)
                response = next(responses)
                if isinstance(response, Exception):
                    raise response
                return response

            sleeps: list[float] = []
            result = publish_hex_tarball.publish(
                tarball,
                "kangaroo",
                "1.0.0",
                api_key="secret",
                opener=opener,
                sleeper=sleeps.append,
            )
            self.assertEqual(result, "published")
            self.assertEqual([call.get_method() for call in calls], [  # type: ignore[attr-defined]
                "GET", "POST", "GET", "GET",
            ])
            post = calls[1]
            self.assertEqual(post.data, payload)  # type: ignore[attr-defined]
            self.assertEqual(post.headers["Authorization"], "secret")  # type: ignore[attr-defined]
            self.assertEqual(sleeps, [5])

    def test_rejects_a_tarball_with_the_wrong_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tarball = Path(directory) / "other-1.0.0.tar"
            fixture_tarball(tarball, package="other")
            with self.assertRaisesRegex(RuntimeError, "does not declare"):
                publish_hex_tarball.publish(
                    tarball,
                    "kangaroo",
                    "1.0.0",
                    api_key="secret",
                    opener=lambda *_args, **_kwargs: Response(404),
                )

    def test_concurrent_already_published_response_verifies_remote_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tarball = Path(directory) / "kangaroo-1.0.0.tar"
            payload = fixture_tarball(tarball)
            responses = iter([
                urllib.error.HTTPError(
                    "url", 404, "missing", {}, io.BytesIO()
                ),
                urllib.error.HTTPError(
                    "url", 422, "already exists", {}, io.BytesIO(b"exists")
                ),
                Response(200, payload),
            ])

            def opener(*_arguments: object, **_options: object) -> object:
                response = next(responses)
                if isinstance(response, Exception):
                    raise response
                return response

            self.assertEqual(
                publish_hex_tarball.publish(
                    tarball,
                    "kangaroo",
                    "1.0.0",
                    api_key="secret",
                    opener=opener,
                ),
                "already-published",
            )


if __name__ == "__main__":
    unittest.main()
