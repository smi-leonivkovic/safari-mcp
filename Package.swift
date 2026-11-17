// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SafariMCP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "safari-mcp", targets: ["SafariMCP"])],
    targets: [.executableTarget(name: "SafariMCP", path: "Sources/SafariMCP")]
)
