#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/realm-write-admission.XXXXXX")"
preserve_scratch() {
    mkdir -p "$HOME/.Trash"
    mv "$scratch" "$HOME/.Trash/"
}
trap preserve_scratch EXIT
mkdir -p "$scratch/Sources/RealmSwiftGaps" "$scratch/Tests/RealmSwiftGapsTests"
# Compile the exact production signal and owning tests, not a second model.
# This intentionally excludes Realm.Private and cannot qualify the SDK bridge.
cp "$root/Sources/RealmSwiftGaps/RealmWriteAdmissionSignal.swift" "$scratch/Sources/RealmSwiftGaps/"
cp "$root/Tests/RealmSwiftGapsTests/RealmWriteAdmissionSignalTests.swift" "$scratch/Tests/RealmSwiftGapsTests/"
cat > "$scratch/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RealmWriteAdmissionIsolation",
    targets: [
        .target(name: "RealmSwiftGaps"),
        .testTarget(name: "RealmSwiftGapsTests", dependencies: ["RealmSwiftGaps"]),
    ]
)
SWIFT
swift test --package-path "$scratch"
