// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Cadence",
            path: "Sources/Cadence",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
