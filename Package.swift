// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CoreAgent",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
    .visionOS(.v26)
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
