import Foundation
import FoundationModels

/// Metadata accepted by Foundation Models for a single generation request.
public typealias CoreAgentRequestMetadata = [String: any Sendable & Codable & Equatable]

public enum CoreAgentError: Error, LocalizedError, Sendable {
  case invalidRetryAttemptCount(Int)
  case invalidDuration(name: String)
  case invalidToolCallLimit(Int)
  case invalidHistoryLimit(Int)
  case invalidObserverQueueLimit(Int)
  case emptyCheckpointCompatibilityID
  case concurrentOperation
  case unsafeRetryConfiguration(String)
  case noActiveRun
  case unsupportedCheckpointVersion(Int)
  case checkpointCompatibilityMismatch(expected: String, actual: String)
  case responseTimedOut
  case streamFinishedWithoutResponse
  case toolCallBudgetExceeded(maximum: Int)
  case toolExecutionTimedOut(toolName: String)

  public var errorDescription: String? {
    switch self {
    case .invalidRetryAttemptCount(let count):
      "Retry attempt count must be at least one; received \(count)."
    case .invalidDuration(let name):
      "\(name) must not be negative."
    case .invalidToolCallLimit(let limit):
      "The tool call limit must be zero or greater; received \(limit)."
    case .invalidHistoryLimit(let limit):
      "The transcript history limit must be zero or greater; received \(limit)."
    case .invalidObserverQueueLimit(let limit):
      "The observer queue limit must be at least one; received \(limit)."
    case .emptyCheckpointCompatibilityID:
      "The dynamic profile checkpoint compatibility ID must not be empty."
    case .concurrentOperation:
      "CoreAgentSession already has an operation in flight."
    case .unsafeRetryConfiguration(let reason):
      "Unsafe retry configuration: \(reason)"
    case .noActiveRun:
      "A governed tool was called without an active CoreAgent run."
    case .unsupportedCheckpointVersion(let version):
      "Checkpoint format version \(version) is unsupported."
    case .checkpointCompatibilityMismatch(let expected, let actual):
      "Checkpoint compatibility revision '\(actual)' does not match the current revision '\(expected)'."
    case .responseTimedOut:
      "The model response exceeded the configured timeout."
    case .streamFinishedWithoutResponse:
      "The model response stream finished without producing a snapshot."
    case .toolCallBudgetExceeded(let maximum):
      "The run exceeded its budget of \(maximum) tool calls."
    case .toolExecutionTimedOut(let toolName):
      "Tool '\(toolName)' exceeded its configured timeout."
    }
  }
}

public struct CoreAgentRetryPolicy: Sendable {
  public let maximumAttempts: Int
  public let delay: Duration
  private let classifier: @Sendable (any Error) -> Bool

  public init(
    maximumAttempts: Int,
    delay: Duration = .zero,
    shouldRetry: @escaping @Sendable (any Error) -> Bool
  ) throws {
    guard maximumAttempts >= 1 else {
      throw CoreAgentError.invalidRetryAttemptCount(maximumAttempts)
    }
    guard delay >= .zero else {
      throw CoreAgentError.invalidDuration(name: "Retry delay")
    }
    self.maximumAttempts = maximumAttempts
    self.delay = delay
    self.classifier = shouldRetry
  }

  public func shouldRetry(_ error: any Error) -> Bool {
    classifier(error)
  }

  public static let none = try! CoreAgentRetryPolicy(maximumAttempts: 1) { _ in false }

  public static func transient(maximumAttempts: Int = 3, delay: Duration = .milliseconds(250))
    throws -> Self
  {
    try Self(maximumAttempts: maximumAttempts, delay: delay) { error in
      if error is CancellationError || error is CoreAgentPolicyError || error is CoreAgentError {
        if let coreError = error as? CoreAgentError, case .responseTimedOut = coreError {
          return true
        }
        return false
      }
      guard let modelError = error as? LanguageModelError else {
        return false
      }
      switch modelError {
      case .rateLimited, .timeout:
        return true
      default:
        return false
      }
    }
  }
}

public struct CoreAgentConfiguration: Sendable {
  public var responseTimeout: Duration?
  public var retryPolicy: CoreAgentRetryPolicy
  public var transcriptErrorHandlingPolicy: CoreAgentTranscriptErrorPolicy
  public var savesTranscriptAfterFailedResponse: Bool
  public var allowsRetryAfterToolInvocation: Bool
  public var checkpointFailurePolicy: CoreAgentCheckpointFailurePolicy

  public init(
    responseTimeout: Duration? = nil,
    retryPolicy: CoreAgentRetryPolicy = .none,
    transcriptErrorHandlingPolicy: CoreAgentTranscriptErrorPolicy = .revert,
    savesTranscriptAfterFailedResponse: Bool = true,
    allowsRetryAfterToolInvocation: Bool = false,
    checkpointFailurePolicy: CoreAgentCheckpointFailurePolicy = .recordAndContinue
  ) {
    self.responseTimeout = responseTimeout
    self.retryPolicy = retryPolicy
    self.transcriptErrorHandlingPolicy = transcriptErrorHandlingPolicy
    self.savesTranscriptAfterFailedResponse = savesTranscriptAfterFailedResponse
    self.allowsRetryAfterToolInvocation = allowsRetryAfterToolInvocation
    self.checkpointFailurePolicy = checkpointFailurePolicy
  }

  public static let `default` = CoreAgentConfiguration()
}

public enum CoreAgentTranscriptErrorPolicy: Sendable {
  case revert
  case preserve

  var nativeValue: TranscriptErrorHandlingPolicy {
    switch self {
    case .revert:
      .revertTranscript
    case .preserve:
      .preserveTranscript
    }
  }
}

public enum CoreAgentCheckpointFailurePolicy: Sendable {
  /// Return a successful model response and record the checkpoint error in the run.
  case recordAndContinue
  /// Fail the run when checkpoint durability is mandatory.
  case failRun
}

public enum CoreAgentInstructionRestorationPolicy: Sendable {
  /// Reuse the instructions encoded in the checkpoint.
  case preserveCheckpoint
  /// Replace checkpoint instructions when current instructions were supplied.
  case replaceWithCurrent
}

public struct CoreAgentUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int

  public init(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    reasoningTokens: Int
  ) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
  }

  init(_ usage: LanguageModelSession.Usage) {
    self.init(
      inputTokens: usage.input.totalTokenCount,
      cachedInputTokens: usage.input.cachedTokenCount,
      outputTokens: usage.output.totalTokenCount,
      reasoningTokens: usage.output.reasoningTokenCount
    )
  }
}

public struct CoreAgentResponse<Content>: Sendable where Content: Generable & Sendable {
  public let content: Content
  public let rawContent: GeneratedContent
  public let transcriptEntries: [Transcript.Entry]
  public let usage: CoreAgentUsage
  public let run: CoreAgentRun

  public init(
    content: Content,
    rawContent: GeneratedContent,
    transcriptEntries: [Transcript.Entry],
    usage: CoreAgentUsage,
    run: CoreAgentRun
  ) {
    self.content = content
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.run = run
  }
}
