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
    ],
    swiftLanguageModes: [.v5]
)
