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
    )
  ],
  targets: [
    .target(name: "KarmaKit"),
    .testTarget(
      name: "KarmaKitTests",
      dependencies: ["KarmaKit"]
    )
  ]
)
