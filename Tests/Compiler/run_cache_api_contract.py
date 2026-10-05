#!/usr/bin/env python3
"""Compile the complete cache source and its public API consumers in Swift 5/6.

RealmSwift and CryptoKit are explicit compiler-surface collaborators. This does
not execute Realm, hashing, file-identity discovery, or the native XCTest suite.
Canonical opening/read-only lookup must compile; configuration-only adoption
must be rejected by the compiler. --expect-legacy checks an exact original source
without relabeling its accepted unsafe API calls as a corrected-source pass.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

CRYPTO = '''import Foundation
// Compiler-surface collaborator only; no hashing is executed.
public enum SHA256 {
    public static func hash(data: Data) -> [UInt8] {
        fatalError("Cryptography is outside this compiler-surface fixture")
    }
}
'''
REALM = '''import Foundation
// Compiler-surface collaborator, not Realm or persisted storage.
open class Object: @unchecked Sendable {
    public class func className() -> String { String(describing: self) }
}
public struct Realm: Sendable {
    public struct Configuration: Sendable {
        public var inMemoryIdentifier: String? = nil
        public var fileURL: URL? = nil
        public var schemaVersion: UInt64 = 0
        public var readOnly = false
        public var maximumNumberOfActiveVersions: UInt? = nil
        public var deleteRealmIfMigrationNeeded = false
        public var seedFilePath: URL? = nil
        public var encryptionKey: Data? = nil
        public var objectTypes: [Object.Type]? = nil
        public init() {}
    }
    public let configuration: Configuration
    public init(configuration: Configuration, actor: isolated any Actor) async throws {
        self.configuration = configuration
    }
}
'''
ERRORS = '''public enum RealmBackgroundActorError: Error {
    case realmFileChangedDuringOpen
}
'''
PRELUDE = '''import RealmSwift
import RealmSwiftGaps
actor Consumer: CachedRealmsActor {
    private var entries = [String: Realm]()
    func getCachedRealm(key: String) async -> Realm? { entries[key] }
    func setCachedRealm(_ realm: Realm, key: String) async { entries[key] = realm }
'''
CONSUMERS = {
    "Canonical": PRELUDE + '''    func useCanonicalOpener(_ configuration: Realm.Configuration) async throws -> Realm {
        try await cachedRealm(for: configuration)
    }
    func readOnlyLookup(_ configuration: Realm.Configuration) async -> Realm? {
        await existingCachedRealm(for: configuration)
    }
}
''',
    "Adopt": PRELUDE + '''    func bypass(_ realm: Realm, _ configuration: Realm.Configuration) async {
        await setCachedRealm(realm, for: configuration)
    }
}
''',
    "AdoptIfNeeded": PRELUDE + '''    func bypass(_ realm: Realm, _ configuration: Realm.Configuration) async -> Realm {
        await setCachedRealmIfNeeded(realm, for: configuration)
    }
}
''',
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument("--swift", default="swiftc")
    parser.add_argument("--expect-legacy", action="store_true")
    args = parser.parse_args()
    source = (args.source or Path(__file__).resolve().parents[2]
              / "Sources/RealmSwiftGaps/CachedRealmsActor.swift").resolve()
    output = args.results_dir.resolve()
    # Preserve completed and failed packets; never reuse a predecessor's logs.
    output.mkdir(parents=True, exist_ok=False)
    inputs = output / "inputs"
    inputs.mkdir()
    data = source.read_bytes()
    (inputs / "CachedRealmsActor.swift").write_bytes(data)
    for name, content in {"CryptoKit": CRYPTO, "RealmSwift": REALM, "Errors": ERRORS, **CONSUMERS}.items():
        (inputs / f"{name}.swift").write_text(content, encoding="utf-8")
    records: list[dict] = []
    summary = {
        "scope": "compiler-surface only; explicit RealmSwift/CryptoKit collaborators; no native behavior execution",
        "source": str(source),
        "source_sha256": hashlib.sha256(data).hexdigest(),
        "source_blob_sha1": hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest(),
        "expected_legacy_surface": args.expect_legacy,
        "invocations": records,
    }

    def execute(command: list[str], log: Path) -> tuple[int, str]:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120)
        log.write_text(result.stdout, encoding="utf-8")
        records.append({"command": command, "exit": result.returncode,
                        "log": str(log.relative_to(output))})
        return result.returncode, result.stdout

    try:
        status, _ = execute([args.swift, "--version"], output / "compiler-version.log")
        if status:
            raise RuntimeError("Could not query the Swift compiler")
        with tempfile.TemporaryDirectory(prefix="realm-cache-api-") as scratch:
            for language in ("5", "6"):
                build = Path(scratch) / f"swift{language}"
                build.mkdir()
                logs = output / f"swift{language}"
                logs.mkdir()
                flags = ["-swift-version", language, "-warnings-as-errors"]
                for name in ("CryptoKit", "RealmSwift"):
                    status, _ = execute([args.swift, *flags, "-parse-as-library", "-emit-module",
                                         "-module-name", name, str(inputs / f"{name}.swift"),
                                         "-emit-module-path", str(build / f"{name}.swiftmodule")],
                                        logs / f"{name}.log")
                    if status:
                        raise RuntimeError(f"Failed to compile the {name} collaborator")
                # The exact old file has pre-existing redundant-public warnings.
                # Retain them; do not edit the baseline or claim it was warning-free.
                module_flags = ["-swift-version", language] if args.expect_legacy else flags
                status, _ = execute([args.swift, *module_flags, "-parse-as-library", "-emit-module",
                                     "-module-name", "RealmSwiftGaps", "-I", str(build),
                                     str(inputs / "CachedRealmsActor.swift"), str(inputs / "Errors.swift"),
                                     "-emit-module-path", str(build / "RealmSwiftGaps.swiftmodule")],
                                    logs / "production-module.log")
                if status:
                    raise RuntimeError("The complete production source did not compile")
                for name in CONSUMERS:
                    status, diagnostic = execute([args.swift, *flags, "-typecheck", "-I", str(build),
                                                   str(inputs / f"{name}.swift")], logs / f"{name}.log")
                    expected_success = args.expect_legacy or name == "Canonical"
                    accepted = (status == 0) == expected_success
                    if not expected_success:
                        accepted = accepted and "is unavailable: Use cachedRealm(for:)" in diagnostic
                    records[-1].update(consumer=name, expected_success=expected_success,
                                       contract_passed=accepted)
                    if not accepted:
                        raise RuntimeError(f"Unexpected compiler outcome: Swift {language}, {name}")
        summary["status"] = "passed"
        print("Six expected compiler outcomes verified in Swift 5/6; native Realm behavior is not qualified.")
        return 0
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        summary.update(status="failed", error=str(error))
        print(f"Cache API contract failed: {error}")
        return 1
    finally:
        (output / "result.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
