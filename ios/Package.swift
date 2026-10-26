// swift-tools-version:5.9
// Core logic as a standalone library so it can be tested on macOS with `swift test` (run from ios/).
// The CocoaPods build compiles Core/ and Engine/ into one module, so Core never imports anything else.
import PackageDescription

let package = Package(
    name: "LongPingCore",
    platforms: [.macOS(.v12), .iOS("15.1")],
    products: [
        .library(name: "LongPingCore", targets: ["LongPingCore"]),
    ],
    targets: [
        .target(
            name: "LongPingCore",
            path: "Core",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "LongPingCoreTests",
            dependencies: ["LongPingCore"],
            path: "CoreTests"
        ),
    ]
)
