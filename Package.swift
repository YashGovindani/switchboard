// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SwitchboardCore", path: "Sources/SwitchboardCore"),
        .executableTarget(
            name: "switchboard",
            dependencies: ["SwitchboardCore"],
            path: "Sources/SwitchboardCLI"
        ),
        .executableTarget(
            name: "SwitchboardApp",
            dependencies: ["SwitchboardCore"],
            path: "Sources/SwitchboardApp"
        ),
    ]
)
