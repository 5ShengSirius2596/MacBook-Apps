// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Rat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Rat", targets: ["Rat"])
    ],
    targets: [
        .executableTarget(
            name: "Rat",
            path: "Sources/Rat",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
