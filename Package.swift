// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SysPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SysPulse", targets: ["SysPulse"])
    ],
    targets: [
        .executableTarget(
            name: "SysPulse",
            path: "Sources/SysPulse"
        )
    ]
)
