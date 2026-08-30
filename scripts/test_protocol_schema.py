#!/usr/bin/env python3
"""Dependency-free contract tests for the published protocol-v1 JSON Schema."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "docs" / "protocol-v1.schema.json"
GOLDEN_PATH = ROOT / "test" / "golden" / "protocol-v1.ndjson"
PROTOCOL_DOC_PATH = ROOT / "docs" / "protocol.md"
SUPPORTED_SCHEMA_KEYS = {
    "$defs",
    "$id",
    "$ref",
    "$schema",
    "additionalProperties",
    "const",
    "enum",
    "items",
    "maximum",
    "minimum",
    "oneOf",
    "pattern",
    "properties",
    "required",
    "title",
    "type",
}


class SchemaError(ValueError):
    """Raised when the committed schema uses an invalid or unsupported shape."""


class ValidationError(ValueError):
    """Raised when a protocol record does not conform to the schema."""


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError(f"duplicate JSON object key {key!r}")
        result[key] = value
    return result


def load_schema() -> dict[str, Any]:
    value = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise SchemaError("protocol schema root must be an object")
    check_schema(value, value)
    return value


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "string":
        return isinstance(value, str)
    if expected == "array":
        return isinstance(value, list)
    if expected == "object":
        return isinstance(value, dict)
    raise SchemaError(f"unsupported JSON Schema type {expected!r}")


def resolve_reference(root: dict[str, Any], reference: str) -> dict[str, Any]:
    if not reference.startswith("#/"):
        raise SchemaError(f"only local JSON Pointer references are supported: {reference!r}")
    value: Any = root
    for escaped_part in reference[2:].split("/"):
        part = escaped_part.replace("~1", "/").replace("~0", "~")
        if not isinstance(value, dict) or part not in value:
            raise SchemaError(f"unresolved JSON Schema reference {reference!r}")
        value = value[part]
    if not isinstance(value, dict):
        raise SchemaError(f"JSON Schema reference is not an object: {reference!r}")
    return value


def check_schema(schema: dict[str, Any], root: dict[str, Any], path: str = "$") -> None:
    unknown = set(schema) - SUPPORTED_SCHEMA_KEYS
    if unknown:
        raise SchemaError(f"{path}: unsupported JSON Schema keywords {sorted(unknown)!r}")
    if "$ref" in schema:
        resolve_reference(root, schema["$ref"])
    for keyword in ("$defs", "properties"):
        children = schema.get(keyword, {})
        if not isinstance(children, dict):
            raise SchemaError(f"{path}.{keyword}: expected an object")
        for name, child in children.items():
            if not isinstance(child, dict):
                raise SchemaError(f"{path}.{keyword}.{name}: expected an object")
            check_schema(child, root, f"{path}.{keyword}.{name}")
    branches = schema.get("oneOf", [])
    if not isinstance(branches, list):
        raise SchemaError(f"{path}.oneOf: expected an array")
    for index, branch in enumerate(branches):
        if not isinstance(branch, dict):
            raise SchemaError(f"{path}.oneOf[{index}]: expected an object")
        check_schema(branch, root, f"{path}.oneOf[{index}]")
    if "items" in schema:
        items = schema["items"]
        if not isinstance(items, dict):
            raise SchemaError(f"{path}.items: expected an object")
        check_schema(items, root, f"{path}.items")


def validate(instance: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$") -> None:
    if "$ref" in schema:
        validate(instance, resolve_reference(root, schema["$ref"]), root, path)

    if "oneOf" in schema:
        branches = schema["oneOf"]
        if not isinstance(branches, list) or not branches:
            raise SchemaError(f"{path}: oneOf must be a non-empty array")
        matches = 0
        for branch in branches:
            if not isinstance(branch, dict):
                raise SchemaError(f"{path}: oneOf entries must be objects")
            try:
                validate(instance, branch, root, path)
            except ValidationError:
                pass
            else:
                matches += 1
        if matches != 1:
            raise ValidationError(f"{path}: expected exactly one matching schema, got {matches}")

    expected_types = schema.get("type")
    if expected_types is not None:
        if isinstance(expected_types, str):
            expected_types = [expected_types]
        if not isinstance(expected_types, list) or not all(
            isinstance(expected, str) for expected in expected_types
        ):
            raise SchemaError(f"{path}: type must be a string or string array")
        if not any(json_type_matches(instance, expected) for expected in expected_types):
            raise ValidationError(f"{path}: value has the wrong JSON type")

    if "const" in schema and instance != schema["const"]:
        raise ValidationError(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise ValidationError(f"{path}: value is not in the declared enum")
    if "pattern" in schema:
        if not isinstance(instance, str) or re.search(schema["pattern"], instance) is None:
            raise ValidationError(f"{path}: string does not match {schema['pattern']!r}")
    if "minimum" in schema:
        if isinstance(instance, bool) or not isinstance(instance, (int, float)):
            raise ValidationError(f"{path}: minimum applies to a non-number")
        if instance < schema["minimum"]:
            raise ValidationError(f"{path}: value is below the declared minimum")
    if "maximum" in schema:
        if isinstance(instance, bool) or not isinstance(instance, (int, float)):
            raise ValidationError(f"{path}: maximum applies to a non-number")
        if instance > schema["maximum"]:
            raise ValidationError(f"{path}: value is above the declared maximum")

    if isinstance(instance, list) and "items" in schema:
        item_schema = schema["items"]
        if not isinstance(item_schema, dict):
            raise SchemaError(f"{path}: items must be an object")
        for index, item in enumerate(instance):
            validate(item, item_schema, root, f"{path}[{index}]")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        if not isinstance(required, list) or not all(isinstance(key, str) for key in required):
            raise SchemaError(f"{path}: required must be a string array")
        missing = [key for key in required if key not in instance]
        if missing:
            raise ValidationError(f"{path}: missing required fields {missing!r}")

        properties = schema.get("properties", {})
        if not isinstance(properties, dict):
            raise SchemaError(f"{path}: properties must be an object")
        for key, value in instance.items():
            property_schema = properties.get(key)
            if property_schema is None:
                if schema.get("additionalProperties") is False:
                    raise ValidationError(f"{path}: unexpected field {key!r}")
                continue
            if not isinstance(property_schema, dict):
                raise SchemaError(f"{path}.{key}: property schema must be an object")
            validate(value, property_schema, root, f"{path}.{key}")


def valid_contract_records() -> list[dict[str, Any]]:
    location = {"file": "test/math_test.gleam", "line": 5, "column": 3}
    failures = [
        {
            "kind": "equality_mismatch",
            "expected": "1",
            "actual": "2",
            "diff": None,
            "location": location,
        },
        {"kind": "assertion_failed", "message": "no", "location": None},
        {
            "kind": "unexpected_error",
            "name": "Error",
            "message": "boom",
            "location": location,
        },
    ]
    outcomes = [
        {"kind": "passed"},
        {"kind": "skipped", "reason": "unsupported"},
        {"kind": "flaky", "attempts": 2, "failures": failures},
        {"kind": "failed", "failures": failures},
    ]
    events = [
        {"type": "run_started", "run_id": 1, "case_count": 1},
        {"type": "case_started", "suite": "math", "case": "math::adds"},
        {
            "type": "case_output",
            "suite": "math",
            "case": "math::adds",
            "stdout": "ok\n",
            "stderr": "",
            "outcome": outcomes[1],
        },
        {
            "type": "case_finished",
            "suite": "math",
            "case": "math::adds",
            "outcome": outcomes[2],
            "duration_ms": 4,
        },
        {"type": "suite_started", "suite": "math"},
        {"type": "suite_finished", "suite": "math", "outcome": outcomes[3]},
        {
            "type": "run_finished",
            "run_id": 1,
            "summary": {"passed": 0, "failed": 1, "skipped": 0, "duration_ms": 4},
        },
    ]
    requests = [
        {"protocol_version": 1, "id": "discover-1", "command": "discover"},
        {
            "protocol_version": 1,
            "id": "run-1",
            "command": "run",
            "selectors": ["math::adds"],
            "include_tags": ["unit"],
            "exclude_tags": ["slow"],
        },
        {"protocol_version": 1, "id": "watch-1", "command": "watch"},
        {
            "protocol_version": 1,
            "id": "cancel-1",
            "command": "cancel",
            "operation_id": "watch-1",
        },
        {"protocol_version": 1, "id": "shutdown-1", "command": "shutdown"},
    ]
    responses: list[dict[str, Any]] = [
        {
            "protocol_version": 1,
            "type": "discovered",
            "request_id": "discover-1",
            "tests": [
                {
                    "id": "math::adds",
                    "name": "adds",
                    "path": "test/math_test.gleam",
                    "module": "math_test",
                    "line": 4,
                    "column": 1,
                    "end_line": 6,
                    "end_column": 2,
                    "tags": ["unit"],
                    "timeout_ms": None,
                    "serial": False,
                }
            ],
        },
        {
            "protocol_version": 1,
            "type": "started",
            "request_id": "run-1",
            "operation_id": "run-1",
            "operation": "run",
        },
        {"protocol_version": 1, "type": "completed", "request_id": "run-1", "exit_code": 0},
        {
            "protocol_version": 1,
            "type": "cancelled",
            "request_id": "cancel-1",
            "operation_id": "watch-1",
        },
        {"protocol_version": 1, "type": "shutdown", "request_id": "shutdown-1"},
        {
            "protocol_version": 1,
            "type": "error",
            "request_id": "bad-1",
            "message": "invalid request",
        },
    ]
    responses.extend(
        {
            "protocol_version": 1,
            "type": "event",
            "request_id": "run-1",
            "event": event,
        }
        for event in events
    )
    return requests + responses


class ProtocolSchemaTest(unittest.TestCase):
    def test_schema_has_unique_object_keys(self) -> None:
        load_schema()

    def test_duplicate_key_guard_is_active(self) -> None:
        with self.assertRaises(SchemaError):
            json.loads('{"type":"object","type":"array"}', object_pairs_hook=unique_object)

    def test_every_golden_response_conforms(self) -> None:
        schema = load_schema()
        for line_number, line in enumerate(GOLDEN_PATH.read_text(encoding="utf-8").splitlines(), 1):
            with self.subTest(line=line_number):
                validate(json.loads(line), schema, schema)

    def test_every_documented_protocol_record_conforms(self) -> None:
        schema = load_schema()
        documentation = PROTOCOL_DOC_PATH.read_text(encoding="utf-8")
        for block in re.findall(r"```json\n(.*?)\n```", documentation, flags=re.DOTALL):
            for line in block.splitlines():
                record = json.loads(line)
                if isinstance(record, dict) and "protocol_version" in record:
                    validate(record, schema, schema)

    def test_every_public_protocol_shape_conforms(self) -> None:
        schema = load_schema()
        for record in valid_contract_records():
            with self.subTest(record=record):
                validate(record, schema, schema)

    def test_invalid_contract_shapes_are_rejected(self) -> None:
        schema = load_schema()
        invalid = [
            {"protocol_version": 1, "id": "", "command": "discover"},
            {"protocol_version": 1, "id": "x", "command": "discover", "extra": True},
            {"protocol_version": 1, "type": "completed", "request_id": "x", "exit_code": 3},
            {
                "protocol_version": 1,
                "type": "event",
                "request_id": "x",
                "event": {"type": "run_started", "run_id": 1, "case_count": -1},
            },
        ]
        for record in invalid:
            with self.subTest(record=record), self.assertRaises(ValidationError):
                validate(record, schema, schema)


if __name__ == "__main__":
    unittest.main()
