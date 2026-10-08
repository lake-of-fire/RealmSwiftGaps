#!/usr/bin/env python3
"""Require individual XCTest outcomes, including SDKs with no XCTest XML export.

Apple SwiftPM may emit only an empty Swift Testing XML file even when XCTest
ran. This parser consumes the retained XCTest event log and process exit; an
empty secondary runner or a suite summary alone cannot satisfy the inventory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

OWNER = "RealmCacheLookupBoundaryTests"
EXPECTED = frozenset({
    "testMissingReadOnlyLookupDoesNotOpenOrCreateARealm",
    "testCurrentCachedRealmRemainsReadableWithoutAnotherInsertion",
    "testSamePathReplacementDuringLookupReturnsMissWithoutInvalidatingOldOwner",
    "testDisappearedPathDuringLookupReturnsMissAndRetainsOriginalOwner",
    "testUnrelatedFileReplacementDoesNotWithdrawCurrentCacheHit",
    "testInMemoryCacheLookupDoesNotDependOnUnrelatedDiskState",
})
CASE = re.compile(
    r"^Test Case '(?:-\[(?P<apple_owner>[\w.]+) (?P<apple_name>\w+)\]|"
    r"(?P<portable_owner>[\w.]+)\.(?P<portable_name>\w+))' "
    r"(?P<outcome>started|passed|failed|skipped)\b"
)


def inspect(log: str, process_status: int, expected_failures: frozenset[str] = frozenset(),
            *, owner: str = OWNER, expected: frozenset[str] = EXPECTED) -> dict:
    errors: list[str] = []
    if not re.fullmatch(r"[A-Za-z_]\w*", owner) or not expected:
        errors.append("Native inventory must name an owning class and at least one method")
    if any(not re.fullmatch(r"test\w+", name) for name in expected):
        errors.append("Invalid required native method identity")
    histories: dict[str, list[str]] = {}
    starts: list[int] = []
    ends: list[tuple[int, str]] = []
    event_lines: list[int] = []
    lines = log.splitlines()
    for number, line in enumerate(lines):
        if line.startswith(f"Test Suite '{owner}' started at "):
            starts.append(number)
        for outcome in ("passed", "failed"):
            if line.startswith(f"Test Suite '{owner}' {outcome} at "):
                ends.append((number, outcome))
        match = CASE.match(line)
        if not match:
            continue
        event_owner = match['apple_owner'] or match['portable_owner']
        if event_owner.split('.')[-1] != owner:
            continue
        name = match['apple_name'] or match['portable_name']
        histories.setdefault(name, []).append(match['outcome'])
        event_lines.append(number)
    if not expected_failures <= expected:
        errors.append("Unknown expected-failure identity")
    expected_status = 1 if expected_failures else 0
    if process_status != expected_status:
        errors.append("Unexpected native process exit")
    if set(histories) != expected:
        errors.append("Missing or unexpected native method identity")
    for name in expected:
        terminal = "failed" if name in expected_failures else "passed"
        if histories.get(name) != ["started", terminal]:
            errors.append(f"Incomplete, duplicate or unexpected outcome: {name}")
    wanted_suite_result = "failed" if expected_failures else "passed"
    if len(starts) != 1 or len(ends) != 1:
        errors.append("Missing or duplicate owning XCTest suite boundary")
    elif ends[0][1] != wanted_suite_result or not all(starts[0] < n < ends[0][0] for n in event_lines):
        errors.append("Native outcomes are not enclosed by the expected owning suite")
    if len(ends) == 1:
        following = lines[ends[0][0] + 1:]
        summary = re.match(r"\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)",
                           following[0] if following else "")
        if not summary or int(summary[1]) != len(expected) or int(summary[3]) != 0:
            errors.append("Missing or inconsistent owning XCTest summary")
        elif (not expected_failures and int(summary[2]) != 0) or int(summary[2]) < len(expected_failures):
            errors.append("Unexpected owning XCTest failure count")
    return {
        "scope": "native Realm XCTest component; not Reader application/UI/CloudKit/performance/Release acceptance",
        "owner": owner,
        "required_methods": sorted(expected),
        "process_status": process_status,
        "expected_failures": sorted(expected_failures),
        "histories": histories,
        "missing": sorted(expected - set(histories)),
        "unexpected": sorted(set(histories) - expected),
        "errors": errors,
        "contract_passed": not errors,
        "native_successful_methods": sum(events == ["started", "passed"] for events in histories.values()),
        "log_sha256": hashlib.sha256(log.encode()).hexdigest(),
        "proof": "individual XCTest start/terminal events and owning suite; secondary Swift Testing XML is not counted",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--expect-failure", action="append", default=[])
    parser.add_argument("--inventory", type=Path,
                        help="Explicit owning class and required method identities; cache inventory remains the default")
    args = parser.parse_args()
    packet = args.packet.resolve()
    try:
        owner, expected = OWNER, EXPECTED
        if args.inventory:
            inventory = json.loads(args.inventory.read_text())
            if not isinstance(inventory, dict):
                raise ValueError("Native inventory must be an object")
            owner, methods = inventory.get("owner"), inventory.get("methods")
            if (not isinstance(owner, str) or not isinstance(methods, list)
                    or not methods or any(not isinstance(name, str) for name in methods)
                    or len(methods) != len(set(methods))):
                raise ValueError("Invalid or duplicate native inventory identities")
            expected = frozenset(methods)
        result = inspect((packet / "swift-test.log").read_text(),
                         int((packet / "process-status.txt").read_text().strip()),
                         frozenset(args.expect_failure), owner=owner, expected=expected)
    except (OSError, ValueError) as error:
        result = {"contract_passed": False, "errors": [str(error)]}
    destination = packet / "method-receipt.json"
    # Never erase a preceding parser result or an incomplete native packet.
    with destination.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps(result, indent=2))
    return 0 if result["contract_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
