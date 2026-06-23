import Foundation
import FoundationModels

public enum CoreAgentSessionMode: String, Codable, Equatable, Sendable {
  case explicitModel
  case dynamicProfile
}

public enum CoreAgentPluginFailurePolicy: Sendable {
  /// Record the failure and continue without the plugin contribution.
  case recordAndContinue
  /// Fail the run when the plugin operation cannot complete.
  case failRun
}

public struct CoreAgentPluginFailurePolicies: Sendable {
  public var preparation: CoreAgentPluginFailurePolicy
  public var completion: CoreAgentPluginFailurePolicy

  public init(
    preparation: CoreAgentPluginFailurePolicy = .recordAndContinue,
    completion: CoreAgentPluginFailurePolicy = .recordAndContinue
  ) {
    self.preparation = preparation
    self.completion = completion
  }

  public static let `default` = CoreAgentPluginFailurePolicies()
}

/// One deterministic text block contributed before the original user prompt.
public struct CoreAgentContextBlock: Equatable, Sendable, Identifiable {
  public let id: String
  public let content: String
  public let attributes: [String: String]

  public init(
    id: String,
    content: String,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.content = content
    self.attributes = attributes
  }
}

public struct CoreAgentPluginEvent: Equatable, Sendable {
  public let name: String
  public let message: String
  public let attributes: [String: String]

  public init(
    name: String,
    message: String,
    attributes: [String: String] = [:]
  ) {
    self.name = name
    self.message = message
    self.attributes = attributes
  }
}

public struct CoreAgentPluginRequest: Sendable {
  public let runID: UUID
  public let prompt: Prompt
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.prompt = prompt
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.mode = mode
  }
}

public struct CoreAgentPluginPreparation: Sendable {
  public let contextBlocks: [CoreAgentContextBlock]
  public let events: [CoreAgentPluginEvent]

  public init(
    contextBlocks: [CoreAgentContextBlock] = [],
    events: [CoreAgentPluginEvent] = []
  ) {
    self.contextBlocks = contextBlocks
    self.events = events
  }

  public static let empty = CoreAgentPluginPreparation()
}

public struct CoreAgentPluginCompletion: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let rawContent: GeneratedContent
  public let transcriptEntries: [Transcript.Entry]
  public let usage: CoreAgentUsage
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    rawContent: GeneratedContent,
    transcriptEntries: [Transcript.Entry],
    usage: CoreAgentUsage,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.mode = mode
  }
}

public struct CoreAgentPluginFailure: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let errorDescription: String
  public let errorType: String
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    error: any Error,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.errorDescription = String(describing: error)
    self.errorType = String(reflecting: Swift.type(of: error))
    self.mode = mode
  }
}

/// Extends a native CoreAgent run without introducing another model abstraction.
public protocol CoreAgentSessionPlugin: Sendable {
  var identifier: String { get }
  var tools: [any Tool] { get }
  var failurePolicies: CoreAgentPluginFailurePolicies { get }

  func prepare(for request: CoreAgentPluginRequest) async throws -> CoreAgentPluginPreparation
  func didComplete(_ completion: CoreAgentPluginCompletion) async throws -> [CoreAgentPluginEvent]
  func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent]
}

extension CoreAgentSessionPlugin {
  public var tools: [any Tool] { [] }
  public var failurePolicies: CoreAgentPluginFailurePolicies { .default }

  public func prepare(for request: CoreAgentPluginRequest) async throws
    -> CoreAgentPluginPreparation
  {
    .empty
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    []
  }
}
