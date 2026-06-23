// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "CoreAgent",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
    .visionOS(.v27),
  ],
  products: [
    .library(name: "CoreAgent", targets: ["CoreAgent"]),
    .library(name: "CoreAgentTestSupport", targets: ["CoreAgentTestSupport"]),
  ],
  targets: [
    .target(name: "CoreAgent"),
    .target(
      name: "CoreAgentTestSupport",
      dependencies: ["CoreAgent"]
    ),
    .testTarget(
      name: "CoreAgentTests",
      dependencies: ["CoreAgent", "CoreAgentTestSupport"]
    ),
  ]
)
