// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RealmSwiftGaps",
    platforms: [.macOS(.v12), .iOS(.v15)],
    products: [
        .library(
            name: "RealmSwiftGaps",
            type: .dynamic,
            targets: ["RealmSwiftGaps"]),
    ],
    dependencies: [
//        .package(url: "https://github.com/lake-of-fire/RealmBinary.git", branch: "main"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.54.4"),
    ],
    targets: [
        .target(
            name: "RealmSwiftGaps",
            dependencies: [
//                .product(name: "RealmSwift", package: "RealmBinary"),
                .product(name: "RealmSwift", package: "realm-swift"),
            ]),
//        .testTarget(
//            name: "RealmSwiftGapsTests",
//            dependencies: ["RealmSwiftGaps"]),
    ]
)
