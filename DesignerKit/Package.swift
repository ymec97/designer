// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignerModel", targets: ["DesignerModel"]),
        .library(name: "DesignerPersistence", targets: ["DesignerPersistence"]),
        .executable(name: "Designer", targets: ["Designer"]),
    ],
    targets: [
        .target(name: "DesignerModel"),
        .target(name: "DesignerPersistence", dependencies: ["DesignerModel"]),
        // The app itself. AppKit glue stays in Swift 5 language mode; the
        // model/persistence/recognition packages are strict Swift 6.
        .executableTarget(
            name: "Designer",
            dependencies: ["DesignerModel", "DesignerPersistence"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DesignerModelTests", dependencies: ["DesignerModel"]),
        .testTarget(name: "DesignerPersistenceTests", dependencies: ["DesignerPersistence"]),
    ]
)
