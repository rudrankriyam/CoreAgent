import CoreAgent
import Foundation

public enum CoreAgentProviderModels {}

public enum CoreAgentProviderFeatures {
  #if COREAGENT_APPLE_UTILITIES
    public static let appleUtilities = true
  #else
    public static let appleUtilities = false
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
