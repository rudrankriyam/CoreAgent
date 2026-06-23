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
    ),
    .trait(
      name: "Claude",
      description: "Enable Anthropic's ClaudeForFoundationModels provider."
    ),
    .trait(
      name: "Gemini",
      description: "Enable Firebase AI Logic's Gemini Foundation Models provider."
    ),
    .trait(
      name: "AllProviders",
      description: "Enable every first-party provider integration.",
      enabledTraits: ["AppleUtilities", "Claude", "Gemini"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/foundation-models-utilities.git",
      revision: "a047a503b8ec79a76aa0e83d5a3bac54493cc7e5"
    ),
    .package(
      url: "https://github.com/anthropics/ClaudeForFoundationModels.git",
      exact: "0.1.2"
    ),
    .package(
      url: "https://github.com/firebase/firebase-ios-sdk.git",
      revision: "eb640a7bd9f8f4e4843e61c12a24c0abe4044443"
    ),
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
        .product(
          name: "ClaudeForFoundationModels",
          package: "ClaudeForFoundationModels",
          condition: .when(traits: ["Claude"])
        ),
        .product(
          name: "FirebaseAILogic",
          package: "firebase-ios-sdk",
          condition: .when(traits: ["Gemini"])
        ),
      ],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("COREAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("COREAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
    .testTarget(
      name: "CoreAgentTests",
      dependencies: ["CoreAgent", "CoreAgentTestSupport", "CoreAgentProviders"],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("COREAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("COREAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
  ]
)
