// swift-tools-version: 5.10
//
//  Marksmith - a native macOS Markdown editor.
//  Zero third-party SwiftPM dependencies: builds fully offline.

import PackageDescription

let package = Package(
    name: "Marksmith",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Marksmith", targets: ["Marksmith"])
    ],
    targets: [
        .executableTarget(
            name: "Marksmith",
            path: "Marksmith",
            exclude: [
                "App/Info.plist",
                "App/AppIcon.icns",
                "App/Marksmith.entitlements"
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "MarksmithTests",
            dependencies: ["Marksmith"],
            path: "Tests/MarksmithTests"
        )
    ]
)
