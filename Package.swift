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
    .library(name: "CoreAgentProviders", targets: ["CoreAgentProviders"]),
  ],
  traits: [
    .trait(
      name: "AppleUtilities",
      description:
        "Enable Apple's FoundationModelsUtilities provider, including OpenAI-compatible Chat Completions."
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/foundation-models-utilities.git",
      revision: "a047a503b8ec79a76aa0e83d5a3bac54493cc7e5"
    )
  ],
  targets: [
    .target(name: "CoreAgent"),
    .target(
      name: "CoreAgentTestSupport",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentProviders",
      dependencies: [
        "CoreAgent",
        .product(
          name: "FoundationModelsUtilities",
          package: "foundation-models-utilities",
          condition: .when(traits: ["AppleUtilities"])
        ),
      ],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"]))
      ]
    ),
    .testTarget(
      name: "CoreAgentTests",
      dependencies: ["CoreAgent", "CoreAgentTestSupport", "CoreAgentProviders"],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"]))
      ]
    ),
  ]
)
