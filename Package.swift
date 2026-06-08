// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "CoreAgent",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
    .visionOS(.v27)
  ],
  products: [
    .library(
      name: "CoreAgent",
      targets: ["CoreAgent"]
    ),
    .library(
      name: "CoreAgentFoundationModels",
      targets: ["CoreAgentFoundationModels"]
    ),
    .library(
      name: "CoreAgentTools",
      targets: ["CoreAgentTools"]
    ),
    .executable(
      name: "core-agent",
      targets: ["CoreAgentCLI"]
    )
  ],
  targets: [
    .target(name: "CoreAgent"),
    .target(
      name: "CoreAgentFoundationModels",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentTools",
      dependencies: ["CoreAgent"]
    ),
    .executableTarget(
      name: "CoreAgentCLI",
      dependencies: [
        "CoreAgent",
        "CoreAgentFoundationModels",
        "CoreAgentTools"
      ]
    ),
    .testTarget(
      name: "CoreAgentTests",
      dependencies: [
        "CoreAgent",
        "CoreAgentFoundationModels",
        "CoreAgentTools"
      ]
    ),
    .testTarget(
      name: "CoreAgentToolsTests",
      dependencies: [
        "CoreAgent",
        "CoreAgentTools"
      ]
    )
  ]
)
