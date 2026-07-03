// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "lutop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lutop", targets: ["Lutop"])
    ],
    targets: [
        .executableTarget(name: "Lutop")
    ]
)
