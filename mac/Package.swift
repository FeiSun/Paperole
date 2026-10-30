// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Paperole",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Paperole", path: "Sources/Paperole"),
        .testTarget(name: "PaperoleTests", dependencies: ["Paperole"], path: "Tests/PaperoleTests"),
    ]
)
