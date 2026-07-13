// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DesignerModel", targets: ["DesignerModel"]),
        .library(name: "DesignerPersistence", targets: ["DesignerPersistence"]),
        .library(name: "DesignerRecognition", targets: ["DesignerRecognition"]),
        .library(name: "DesignerInterop", targets: ["DesignerInterop"]),
        .library(name: "DesignerAgent", targets: ["DesignerAgent"]),
        .library(name: "DesignerCanvas", targets: ["DesignerCanvas"]),
        .executable(name: "Designer", targets: ["Designer"]),
    ],
    targets: [
        .target(name: "DesignerModel"),
        .target(name: "DesignerPersistence", dependencies: ["DesignerModel"]),
        // Sketch → structure: pure geometric stroke recognition (D15).
        .target(name: "DesignerRecognition", dependencies: ["DesignerModel"]),
        // Import/export: LLM text interchange (D16), SVG. No UI deps.
        .target(name: "DesignerInterop", dependencies: ["DesignerModel", "DesignerPersistence"]),
        // Agent surface (F4): local MCP server exposing the board to an agent.
        // Foundation + Network only, no UI. Swift 5 mode for the transport.
        .target(
            name: "DesignerAgent",
            dependencies: ["DesignerModel", "DesignerInterop"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
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
            dependencies: [
                "DesignerModel", "DesignerPersistence", "DesignerCanvas",
                "DesignerRecognition", "DesignerInterop", "DesignerAgent",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "DesignerModelTests", dependencies: ["DesignerModel"]),
        .testTarget(name: "DesignerPersistenceTests", dependencies: ["DesignerPersistence"]),
        .testTarget(name: "DesignerRecognitionTests", dependencies: ["DesignerRecognition"]),
        .testTarget(name: "DesignerInteropTests", dependencies: ["DesignerInterop"]),
        .testTarget(
            name: "DesignerAgentTests",
            dependencies: ["DesignerAgent"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DesignerCanvasTests",
            dependencies: ["DesignerCanvas"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
