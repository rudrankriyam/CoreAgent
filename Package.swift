// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "KarmaKit",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2)
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
