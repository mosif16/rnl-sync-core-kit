// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SyncCoreKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SyncCoreKit",
            targets: ["SyncCoreKit"]
        )
    ],
    targets: [
        .target(
            name: "SyncCoreKit"
        ),
        .testTarget(
            name: "SyncCoreKitTests",
            dependencies: ["SyncCoreKit"]
        )
    ]
)
