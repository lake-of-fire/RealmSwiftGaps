// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RealmSwiftGaps",
    platforms: [.macOS("15.0"), .iOS(.v15)],
    products: [
        .library(
            name: "RealmSwiftGaps",
            type: .static,
            targets: ["RealmSwiftGaps"]),
    ],
    dependencies: [
        // The owned-write bridge relies on Realm.Private begin tickets and
        // frozen-version identity reviewed against this exact SDK. Requalify
        // those contracts before advancing Realm; consumer lockfiles alone
        // cannot constrain fresh package resolutions.
        .package(url: "https://github.com/realm/realm-swift.git", exact: "20.0.5"),
    ],
    targets: [
        .target(
            name: "RealmSwiftGaps",
            dependencies: [
                .product(name: "RealmSwift", package: "realm-swift"),
            ]),
        .testTarget(
            name: "RealmSwiftGapsTests",
            dependencies: [
                "RealmSwiftGaps",
                .product(name: "RealmSwift", package: "realm-swift"),
            ]),
    ]
)
