// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DishWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DishWatch", targets: ["DishWatch"]),
    ],
    targets: [
        .executableTarget(
            name: "DishWatch",
            path: "Sources/DishWatch"
        ),
        // Tests import the executable target directly. That works because the
        // @main type lives in DishWatchApp.swift rather than a top-level
        // main.swift, so SwiftPM builds the module with -parse-as-library and
        // there is no duplicate entry point to collide with.
        .testTarget(
            name: "DishWatchTests",
            dependencies: ["DishWatch"],
            path: "Tests/DishWatchTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
