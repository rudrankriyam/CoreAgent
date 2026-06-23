import Foundation
import FoundationModels

public enum RecordedLanguageModelError: Error, LocalizedError, Sendable {
  case scriptExhausted
  case scriptedFailure(String)

  public var errorDescription: String? {
    switch self {
    case .scriptExhausted:
      "The recorded language model script has no remaining steps."
    case .scriptedFailure(let message):
      message
    }
  }
}

public enum RecordedLanguageModelStep: Sendable {
  case response(
    text: String,
    inputTokens: Int = 1,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 1,
    reasoningTokens: Int = 0
  )
  case responseFragments([String])
  case toolCall(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    argumentsJSON: String,
    inputTokens: Int = 1,
    outputTokens: Int = 1
  )
  case delayedResponse(text: String, delay: Duration)
  case failure(String)
}

public final class RecordedLanguageModelRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var steps: [RecordedLanguageModelStep]
  private var requestTranscripts: [Transcript] = []

  public init(steps: [RecordedLanguageModelStep]) {
    self.steps = steps
  }

  public func capturedTranscripts() -> [Transcript] {
    lock.withLock { requestTranscripts }
  }

  fileprivate func next(for request: LanguageModelExecutorGenerationRequest) throws
    -> RecordedLanguageModelStep
  {
    try lock.withLock {
      requestTranscripts.append(request.transcript)
      guard !steps.isEmpty else {
        throw RecordedLanguageModelError.scriptExhausted
      }
      return steps.removeFirst()
    }
  }
}

public struct RecordedLanguageModel: LanguageModel {
  public typealias Executor = RecordedLanguageModelExecutor

  public let recorder: RecordedLanguageModelRecorder
  public let capabilities: LanguageModelCapabilities

  public init(
    steps: [RecordedLanguageModelStep],
    capabilities: [LanguageModelCapabilities.Capability] = [
      .guidedGeneration,
      .toolCalling,
    ]
  ) {
    self.recorder = RecordedLanguageModelRecorder(steps: steps)
    self.capabilities = LanguageModelCapabilities(capabilities: capabilities)
  }

  public var executorConfiguration: RecordedLanguageModelExecutor.Configuration {
    .init(recorder: recorder)
  }
}

public struct RecordedLanguageModelExecutor: LanguageModelExecutor {
  public typealias Model = RecordedLanguageModel

  public struct Configuration: Hashable, Sendable {
    fileprivate let recorder: RecordedLanguageModelRecorder

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.recorder === rhs.recorder
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(recorder))
    }
  }

  private let recorder: RecordedLanguageModelRecorder

  public init(configuration: Configuration) throws {
    self.recorder = configuration.recorder
  }

  nonisolated(nonsending)
    public func respond(
      to request: LanguageModelExecutorGenerationRequest,
      model: RecordedLanguageModel,
      streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws
  {
    switch try recorder.next(for: request) {
    case .response(
      let text,
      let inputTokens,
      let cachedInputTokens,
      let outputTokens,
      let reasoningTokens
    ):
      await channel.send(
        .response(action: .appendText(text, tokenCount: outputTokens))
      )
      await channel.send(
        .response(
          action: .updateUsage(
            input: .init(
              totalTokenCount: inputTokens,
              cachedTokenCount: cachedInputTokens
            ),
            output: .init(
              totalTokenCount: outputTokens,
              reasoningTokenCount: reasoningTokens
            )
          )
        )
      )

    case .toolCall(
      let id,
      let name,
      let argumentsJSON,
      let inputTokens,
      let outputTokens
    ):
      await channel.send(
        .toolCalls(
          action: .toolCall(
            id: id,
            name: name,
            action: .appendArguments(argumentsJSON, tokenCount: outputTokens)
          )
        )
      )
      await channel.send(
        .toolCalls(
          action: .updateUsage(
            input: .init(totalTokenCount: inputTokens, cachedTokenCount: 0),
            output: .init(totalTokenCount: outputTokens, reasoningTokenCount: 0)
          )
        )
      )

    case .responseFragments(let fragments):
      for fragment in fragments {
        await channel.send(
          .response(action: .appendText(fragment, tokenCount: 1))
        )
      }
      await channel.send(
        .response(
          action: .updateUsage(
            input: .init(totalTokenCount: 1, cachedTokenCount: 0),
            output: .init(totalTokenCount: fragments.count, reasoningTokenCount: 0)
          )
        )
      )

    case .failure(let message):
      throw RecordedLanguageModelError.scriptedFailure(message)

    case .delayedResponse(let text, let delay):
      try await Task.sleep(for: delay)
      await channel.send(
        .response(action: .appendText(text, tokenCount: 1))
      )
      await channel.send(
        .response(
          action: .updateUsage(
            input: .init(totalTokenCount: 1, cachedTokenCount: 0),
            output: .init(totalTokenCount: 1, reasoningTokenCount: 0)
          )
        )
      )
    }
  }
}
