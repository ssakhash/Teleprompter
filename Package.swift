// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeleprompterKit",
    platforms: [.macOS("26.0")],
    products: [.library(name: "TeleprompterKit", targets: ["TeleprompterKit"]),
               .executable(name: "MediaProbe", targets: ["MediaProbe"])],
    targets: [
        .target(name: "CaptureDeviceBridge", linkerSettings: [.linkedFramework("AVFoundation")]),
        .target(name: "TeleprompterKit", dependencies: ["CaptureDeviceBridge"]),
        .executableTarget(name: "MediaProbe", dependencies: ["TeleprompterKit"], path: "Tools/MediaProbe"),
        .testTarget(name: "TeleprompterKitTests", dependencies: ["TeleprompterKit"])
    ]
)
