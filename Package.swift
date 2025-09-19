// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "airportx",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "airportx",
            path: ".",
            sources: ["airportx.swift"],
            linkerSettings: [
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        )
    ]
)
