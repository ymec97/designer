// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignerModel", targets: ["DesignerModel"]),
        .library(name: "DesignerPersistence", targets: ["DesignerPersistence"]),
        .library(name: "DesignerCanvas", targets: ["DesignerCanvas"]),
        .executable(name: "Designer", targets: ["Designer"]),
    ],
    targets: [
        .target(name: "DesignerModel"),
        .target(name: "DesignerPersistence", dependencies: ["DesignerModel"]),
        // AppKit canvas: rendering, viewport, input. Swift 5 language mode
        // like the app target (AppKit APIs); model stays strict Swift 6.
        .target(
            name: "DesignerCanvas",
            dependencies: ["DesignerModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app itself.
        .executableTarget(
            name: "Designer",
            dependencies: ["DesignerModel", "DesignerPersistence", "DesignerCanvas"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DesignerModelTests", dependencies: ["DesignerModel"]),
        .testTarget(name: "DesignerPersistenceTests", dependencies: ["DesignerPersistence"]),
        .testTarget(
            name: "DesignerCanvasTests",
            dependencies: ["DesignerCanvas"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
