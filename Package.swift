// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Wizzzee",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wizzzee",
            path: "Sources/Wizzzee",
            swiftSettings: [
                // The scan engine deliberately shares mutable state across worker
                // threads under its own locks; Swift 6 strict concurrency can't see
                // that, so build the module in Swift 5 mode.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
