// swift-tools-version: 6.2
// HeadsUp: one package, two modules (ADR-001 §1, §3).
//
// HeadsUpCore holds the logic and builds and is tested on Linux and macOS.
// HeadsUpApp is the macOS shell, so the manifest adds it only when it runs on macOS.

import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

var products: [Product] = []
var targets: [Target] = [
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "HeadsUpCore",
        dependencies: [
            "CSQLite",
            .product(name: "Markdown", package: "swift-markdown"),
        ],
        swiftSettings: strict
    ),
    .testTarget(
        name: "HeadsUpCoreTests",
        dependencies: [
            "HeadsUpCore",
            "CSQLite",
            .product(name: "Markdown", package: "swift-markdown"),
        ],
        swiftSettings: strict
    ),
]

#if os(macOS)
    products.append(.executable(name: "HeadsUp", targets: ["HeadsUpApp"]))
    targets.append(
        .executableTarget(
            name: "HeadsUpApp",
            dependencies: ["HeadsUpCore"],
            swiftSettings: strict
        )
    )
#endif

let package = Package(
    name: "HeadsUp",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0")
    ],
    targets: targets
)
