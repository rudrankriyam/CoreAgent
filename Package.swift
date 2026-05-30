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
    .executableTarget(
      name: "KarmaCLI",
      dependencies: [
        "KarmaKit",
        "KarmaKitFoundationModels"
      ]
    ),
    .testTarget(
      name: "KarmaKitTests",
      dependencies: [
        "KarmaKit",
        "KarmaKitFoundationModels"
      ]
    )
  ]
)
