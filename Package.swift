// swift-tools-version:6.2
import PackageDescription

let settings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "openvm-core",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openvm", targets: ["OpenVMApp"])
    ],
    targets: [
        .target(name: "OpenVMCore", swiftSettings: settings),
        .target(name: "OpenVMWindows", swiftSettings: settings),
        .target(
            name: "OpenVMHost",
            dependencies: ["OpenVMCore", "OpenVMWindows"],
            path: "Sources/OpenVMHost",
            swiftSettings: settings
        ),
        .executableTarget(
            name: "OpenVMApp",
            dependencies: ["OpenVMCore", "OpenVMHost"],
            path: "Sources/OpenVMApp",
            swiftSettings: settings
        ),
        .executableTarget(
            name: "openvm-mockguest",
            dependencies: ["OpenVMCore"],
            path: "Sources/openvm-mockguest",
            swiftSettings: settings
        ),
        .executableTarget(
            name: "openvmd",
            dependencies: ["OpenVMHost"],
            path: "Sources/openvmd",
            swiftSettings: settings
        ),
        .executableTarget(
            name: "openvmctl",
            dependencies: ["OpenVMCore"],
            path: "Sources/openvmctl",
            swiftSettings: settings
        ),
        .testTarget(
            name: "OpenVMDaemonTests",
            dependencies: ["OpenVMHost", "OpenVMWindows"],
            path: "Tests/OpenVMDaemonTests",
            swiftSettings: settings
        ),
        .testTarget(
            name: "OpenVMAppTests",
            dependencies: ["OpenVMApp", "OpenVMHost"],
            path: "Tests/OpenVMAppTests",
            swiftSettings: settings
        ),
        .testTarget(
            name: "OpenVMCoreTests",
            dependencies: ["OpenVMCore"],
            path: "Tests/OpenVMCoreTests",
            swiftSettings: settings
        ),
    ]
)
