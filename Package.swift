// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Yubisashi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Yubisashi",
            path: "Sources/Yubisashi",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
