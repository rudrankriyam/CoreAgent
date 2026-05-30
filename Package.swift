// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "KarmaKit",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
    .visionOS(.v26)
  ],
  products: [
    .library(
      name: "KarmaKit",
      targets: ["KarmaKit"]
    ),
    .library(
      name: "KarmaKitFoundationModels",
      targets: ["KarmaKitFoundationModels"]
    ),
    .library(
      name: "KarmaKitTools",
      targets: ["KarmaKitTools"]
    ),
    .executable(
      name: "karma",
      targets: ["KarmaCLI"]
    )
  ],
  targets: [
    .target(name: "KarmaKit"),
    .target(
      name: "KarmaKitFoundationModels",
      dependencies: ["KarmaKit"]
    ),
    .target(
      name: "KarmaKitTools",
      dependencies: ["KarmaKit"]
    ),
    .executableTarget(
      name: "KarmaCLI",
      dependencies: [
        "KarmaKit",
        "KarmaKitFoundationModels",
        "KarmaKitTools"
      ]
    ),
    .testTarget(
      name: "KarmaKitTests",
      dependencies: [
        "KarmaKit",
        "KarmaKitFoundationModels",
        "KarmaKitTools"
      ]
    ),
    .testTarget(
      name: "KarmaKitToolsTests",
      dependencies: [
        "KarmaKit",
        "KarmaKitTools"
      ]
    )
  ]
)
