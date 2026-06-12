// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AeroSpacePreview",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AeroSpacePreview",
            path: "Sources/AeroSpacePreview"
        ),
        .testTarget(
            name: "AeroSpacePreviewTests",
            dependencies: ["AeroSpacePreview"],
            path: "Tests/AeroSpacePreviewTests"
        )
    ]
)
