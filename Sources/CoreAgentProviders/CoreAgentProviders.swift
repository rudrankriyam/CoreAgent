import CoreAgent
import Foundation

public enum CoreAgentProviderModels {}

public enum CoreAgentProviderFeatures {
  #if COREAGENT_APPLE_UTILITIES
    public static let appleUtilities = true
  #else
    public static let appleUtilities = false
  #endif

  #if COREAGENT_CLAUDE
    public static let claude = true
  #else
    public static let claude = false
  #endif
}

#if COREAGENT_APPLE_UTILITIES
  import FoundationModelsUtilities

  /// Apple's generic OpenAI-compatible Chat Completions language model.
  public typealias OpenAICompatibleLanguageModel = ChatCompletionsLanguageModel

  extension CoreAgentProviderModels {
    public static func openAICompatible(
      name: String,
      baseURL: URL,
      headers: [String: String] = [:],
      supportsGuidedGeneration: Bool = true
    ) -> OpenAICompatibleLanguageModel {
      OpenAICompatibleLanguageModel(
        name: name,
        url: baseURL,
        additionalHeaders: headers,
        supportsGuidedGeneration: supportsGuidedGeneration
      )
    }
  }
#endif

#if COREAGENT_CLAUDE
  import ClaudeForFoundationModels

  /// Anthropic's first-party Foundation Models implementation.
  public typealias AnthropicLanguageModel = ClaudeLanguageModel
  public typealias AnthropicModel = ClaudeModel
  public typealias AnthropicAuthMode = AuthMode
  public typealias AnthropicServerTool = ClaudeServerTool

  extension CoreAgentProviderModels {
    public static func claude(
      model: AnthropicModel = .sonnet4_6,
      auth: AnthropicAuthMode,
      fixedEffort: AnthropicModel.Effort? = nil,
      serverTools: Set<AnthropicServerTool> = [],
      baseURL: URL = AnthropicLanguageModel.defaultBaseURL,
      timeout: TimeInterval = 60
    ) -> AnthropicLanguageModel {
      AnthropicLanguageModel(
        name: model,
        auth: auth,
        fixedEffort: fixedEffort,
        serverTools: serverTools,
        baseURL: baseURL,
        timeout: timeout
      )
    }
  }
#endif
