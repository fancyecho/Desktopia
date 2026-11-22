// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Desktopia",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Desktopia",
            path: "Sources/Desktopia",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
