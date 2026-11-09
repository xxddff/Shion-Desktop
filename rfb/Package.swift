// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RFB",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RFB", targets: ["RFB"]),
        .library(name: "RFBNetwork", targets: ["RFBNetwork"]),
        .executable(name: "rfb-probe", targets: ["rfb-probe"]),
    ],
    targets: [
        // The system zlib (libz on macOS, zlib1g-dev on Debian/Ubuntu).
        .systemLibrary(name: "CZlib", path: "Sources/CZlib", providers: [.apt(["zlib1g-dev"])]),
        // Platform-independent protocol core: handshake, messages, decoders, framebuffer. No Foundation.
        .target(name: "RFB", dependencies: ["CZlib"]),
        // Transports: URLSessionWebSocketTask (Apple), plus a small ws:// client and raw TCP / Unix sockets.
        .target(name: "RFBNetwork", dependencies: ["RFB"]),
        .executableTarget(name: "rfb-probe", dependencies: ["RFB", "RFBNetwork"]),
        .testTarget(name: "RFBTests", dependencies: ["RFB", "RFBNetwork"], resources: [.copy("Samples")]),
    ]
)
