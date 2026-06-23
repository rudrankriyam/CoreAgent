import CoreAgent
import CoreAgentProviders
import Foundation
import Testing

#if COREAGENT_APPLE_UTILITIES
  @Suite("Apple utilities provider smoke tests")
  struct AppleUtilitiesProviderTests {
    @Test("Constructs the OpenAI-compatible provider without a request or API key")
    func constructionOnly() throws {
      let model = CoreAgentProviderModels.openAICompatible(
        name: "placeholder",
        baseURL: URL(string: "https://example.invalid")!,
        supportsGuidedGeneration: false
      )
      _ = try CoreAgentSession(model: model)
      #expect(CoreAgentProviderFeatures.appleUtilities)
    }
  }
#endif

#if COREAGENT_CLAUDE
  @Suite("Claude provider smoke tests")
  struct ClaudeProviderTests {
    @Test("Constructs the first-party Claude provider without sending a request")
    func constructionOnly() throws {
      let model = CoreAgentProviderModels.claude(auth: .apiKey("unused-placeholder"))
      _ = try CoreAgentSession(model: model)
      #expect(CoreAgentProviderFeatures.claude)
    }
  }
#endif

#if COREAGENT_GEMINI
  @Suite("Gemini provider smoke tests")
  struct GeminiProviderTests {
    @Test("Compiles the first-party Gemini provider without requiring Firebase configuration")
    func compileOnly() {
      #expect(CoreAgentProviderFeatures.gemini)
    }

    // This function is deliberately not executed. Constructing FirebaseAI at
    // runtime requires an app's GoogleService-Info.plist, while type-checking it
    // proves the adapter returns a Foundation Models LanguageModel accepted by
    // CoreAgent with no network request or secret.
    private func compileSession(client: FirebaseAIClient) throws {
      let model = CoreAgentProviderModels.gemini(using: client, name: "gemini-placeholder")
      _ = try CoreAgentSession(model: model)
    }
  }
#endif
