import Foundation
import FoundationModels
import CoreAgent

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelProviderError: Error, CustomStringConvertible, Equatable, Sendable {
  case unavailable(String)
  case unsupportedToolInputType(String)
  case invalidToolInputSchema(String)
  case invalidToolArguments(tool: String, message: String)

  public var description: String {
    switch self {
    case .unavailable(let reason):
      return "Foundation Models is unavailable: \(reason)"
    case .unsupportedToolInputType(let type):
      return "Foundation Models does not support tool input type '\(type)' yet."
    case .invalidToolInputSchema(let message):
      return "Invalid tool input schema: \(message)"
    case .invalidToolArguments(let tool, let message):
      return "Invalid arguments for tool '\(tool)': \(message)"
    }
  }
}

public struct FoundationModelToolExecutionError: AgentEventProvidingError, CustomStringConvertible {
  public var underlyingDescription: String
  public var agentEvents: [AgentEvent]

  public init(underlyingDescription: String, agentEvents: [AgentEvent]) {
    self.underlyingDescription = underlyingDescription
    self.agentEvents = agentEvents
  }

  public var description: String {
    "Foundation Models tool execution failed: \(underlyingDescription)"
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelRuntimeKind: String, Codable, Equatable, Sendable {
  case system
  case privateCloudCompute
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelRuntimeSelection: Sendable {
  case system(SystemLanguageModel = .default)
  case privateCloudCompute(PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel())
  case preferPrivateCloudCompute(
    privateCloudCompute: PrivateCloudComputeLanguageModel = PrivateCloudComputeLanguageModel(),
    onDeviceModel: SystemLanguageModel = .default
  )

  public func resolve() -> FoundationModelRuntime {
    switch self {
    case .system(let model):
      return .system(model)
    case .privateCloudCompute(let model):
      return .privateCloudCompute(model)
    case .preferPrivateCloudCompute(let privateCloudCompute, let onDeviceModel):
      switch privateCloudCompute.availability {
      case .available:
        return .privateCloudCompute(privateCloudCompute)
      case .unavailable:
        return .system(onDeviceModel)
      }
    }
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelRuntimeSnapshot: Codable, Equatable, Sendable {
  public var kind: FoundationModelRuntimeKind
  public var isAvailable: Bool
  public var availabilityDescription: String
  public var contextSize: Int?
  public var supportsVision: Bool
  public var supportsGuidedGeneration: Bool
  public var supportsReasoning: Bool
  public var supportsToolCalling: Bool
  public var privateCloudComputeQuota: PrivateCloudComputeQuotaSnapshot?
  public var supportsCurrentLocale: Bool?

  public init(
    kind: FoundationModelRuntimeKind,
    isAvailable: Bool,
    availabilityDescription: String,
    contextSize: Int?,
    supportsVision: Bool,
    supportsGuidedGeneration: Bool,
    supportsReasoning: Bool,
    supportsToolCalling: Bool,
    privateCloudComputeQuota: PrivateCloudComputeQuotaSnapshot? = nil,
    supportsCurrentLocale: Bool? = nil
  ) {
    self.kind = kind
    self.isAvailable = isAvailable
    self.availabilityDescription = availabilityDescription
    self.contextSize = contextSize
    self.supportsVision = supportsVision
    self.supportsGuidedGeneration = supportsGuidedGeneration
    self.supportsReasoning = supportsReasoning
    self.supportsToolCalling = supportsToolCalling
    self.privateCloudComputeQuota = privateCloudComputeQuota
    self.supportsCurrentLocale = supportsCurrentLocale
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct PrivateCloudComputeQuotaSnapshot: Codable, Equatable, Sendable {
  public var statusDescription: String
  public var isLimitReached: Bool
  public var isApproachingLimit: Bool?
  public var resetDate: Date?
  public var hasLimitIncreaseSuggestion: Bool

  public init(
    statusDescription: String,
    isLimitReached: Bool,
    isApproachingLimit: Bool?,
    resetDate: Date?,
    hasLimitIncreaseSuggestion: Bool
  ) {
    self.statusDescription = statusDescription
    self.isLimitReached = isLimitReached
    self.isApproachingLimit = isApproachingLimit
    self.resetDate = resetDate
    self.hasLimitIncreaseSuggestion = hasLimitIncreaseSuggestion
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelRuntime: Sendable {
  case system(SystemLanguageModel)
  case privateCloudCompute(PrivateCloudComputeLanguageModel)

  public static var `default`: FoundationModelRuntime {
    .system(.default)
  }

  public var kind: FoundationModelRuntimeKind {
    switch self {
    case .system:
      .system
    case .privateCloudCompute:
      .privateCloudCompute
    }
  }

  public var isAvailable: Bool {
    switch self {
    case .system(let model):
      model.isAvailable
    case .privateCloudCompute(let model):
      model.isAvailable
    }
  }

  public var availabilityDescription: String {
    switch self {
    case .system(let model):
      String(describing: model.availability)
    case .privateCloudCompute(let model):
      String(describing: model.availability)
    }
  }

  public func contextSize() async throws -> Int {
    switch self {
    case .system(let model):
      model.contextSize
    case .privateCloudCompute(let model):
      try await model.contextSize
    }
  }

  public func snapshot() async -> FoundationModelRuntimeSnapshot {
    let resolvedContextSize = try? await contextSize()
    let runtimeCapabilities = capabilities
    switch self {
    case .system:
      return FoundationModelRuntimeSnapshot(
        kind: kind,
        isAvailable: isAvailable,
        availabilityDescription: availabilityDescription,
        contextSize: resolvedContextSize,
        supportsVision: runtimeCapabilities.contains(.vision),
        supportsGuidedGeneration: runtimeCapabilities.contains(.guidedGeneration),
        supportsReasoning: runtimeCapabilities.contains(.reasoning),
        supportsToolCalling: runtimeCapabilities.contains(.toolCalling)
      )
    case .privateCloudCompute(let model):
      return FoundationModelRuntimeSnapshot(
        kind: kind,
        isAvailable: isAvailable,
        availabilityDescription: availabilityDescription,
        contextSize: resolvedContextSize,
        supportsVision: runtimeCapabilities.contains(.vision),
        supportsGuidedGeneration: runtimeCapabilities.contains(.guidedGeneration),
        supportsReasoning: runtimeCapabilities.contains(.reasoning),
        supportsToolCalling: runtimeCapabilities.contains(.toolCalling),
        privateCloudComputeQuota: PrivateCloudComputeQuotaSnapshot(quotaUsage: model.quotaUsage),
        supportsCurrentLocale: model.supportsLocale()
      )
    }
  }

  private var capabilities: LanguageModelCapabilities {
    switch self {
    case .system(let model):
      model.capabilities
    case .privateCloudCompute(let model):
      model.capabilities
    }
  }

  func validateAvailability() throws {
    switch self {
    case .system(let model):
      switch model.availability {
      case .available:
        return
      case .unavailable(let reason):
        throw FoundationModelProviderError.unavailable(String(describing: reason))
      }
    case .privateCloudCompute(let model):
      switch model.availability {
      case .available:
        return
      case .unavailable(let reason):
        throw FoundationModelProviderError.unavailable(String(describing: reason))
      }
    }
  }

  func makeSession(
    tools: [any FoundationModels.Tool],
    instructions: String?
  ) -> LanguageModelSession {
    switch self {
    case .system(let model):
      LanguageModelSession(model: model, tools: tools, instructions: instructions)
    case .privateCloudCompute(let model):
      LanguageModelSession(model: model, tools: tools, instructions: instructions)
    }
  }

  func makeSession(instructions: String?) -> LanguageModelSession {
    switch self {
    case .system(let model):
      LanguageModelSession(model: model, instructions: instructions)
    case .privateCloudCompute(let model):
      LanguageModelSession(model: model, instructions: instructions)
    }
  }

  func tokenCount(for prompt: String) async throws -> Int? {
    switch self {
    case .system(let model):
      try await model.tokenCount(for: prompt)
    case .privateCloudCompute:
      nil
    }
  }

  func tokenCount(for prompt: Prompt) async throws -> Int? {
    switch self {
    case .system(let model):
      try await model.tokenCount(for: prompt)
    case .privateCloudCompute:
      nil
    }
  }

  func tokenCount(for tools: [any FoundationModels.Tool]) async throws -> Int? {
    guard !tools.isEmpty else {
      return nil
    }

    switch self {
    case .system(let model):
      return try await model.tokenCount(for: tools)
    case .privateCloudCompute:
      return nil
    }
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
private extension PrivateCloudComputeQuotaSnapshot {
  init(quotaUsage: PrivateCloudComputeLanguageModel.QuotaUsage) {
    let statusDescription: String
    let isApproachingLimit: Bool?
    switch quotaUsage.status {
    case .belowLimit(let belowLimit):
      statusDescription = belowLimit.isApproachingLimit ? "belowLimitApproaching" : "belowLimit"
      isApproachingLimit = belowLimit.isApproachingLimit
    case .limitReached:
      statusDescription = "limitReached"
      isApproachingLimit = nil
    @unknown default:
      statusDescription = String(describing: quotaUsage.status)
      isApproachingLimit = nil
    }
    self.init(
      statusDescription: statusDescription,
      isLimitReached: quotaUsage.isLimitReached,
      isApproachingLimit: isApproachingLimit,
      resetDate: quotaUsage.resetDate,
      hasLimitIncreaseSuggestion: quotaUsage.limitIncreaseSuggestion != nil
    )
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelProvider: StreamingModelProvider {
  public var runtime: FoundationModelRuntime {
    didSet {
      runtimeSelection = nil
    }
  }
  public private(set) var runtimeSelection: FoundationModelRuntimeSelection?
  public var instructions: String?
  public var options: GenerationOptions
  public var contextOptions: ContextOptions
  public var toolExecutionPolicy: any ToolExecutionPolicy

  public func contextSize() async throws -> Int {
    try await activeRuntime().contextSize()
  }

  public func runtimeSnapshot() async -> FoundationModelRuntimeSnapshot {
    await activeRuntime().snapshot()
  }

  public init(
    model: SystemLanguageModel = .default,
    instructions: String? = nil,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    toolExecutionPolicy: any ToolExecutionPolicy = AllowAllToolExecutionPolicy()
  ) {
    self.init(
      runtime: .system(model),
      instructions: instructions,
      options: options,
      contextOptions: contextOptions,
      toolExecutionPolicy: toolExecutionPolicy
    )
  }

  public init(
    runtime: FoundationModelRuntime,
    instructions: String? = nil,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    toolExecutionPolicy: any ToolExecutionPolicy = AllowAllToolExecutionPolicy()
  ) {
    self.runtime = runtime
    self.runtimeSelection = nil
    self.instructions = instructions
    self.options = options
    self.contextOptions = contextOptions
    self.toolExecutionPolicy = toolExecutionPolicy
  }

  public init(
    selection: FoundationModelRuntimeSelection,
    instructions: String? = nil,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    toolExecutionPolicy: any ToolExecutionPolicy = AllowAllToolExecutionPolicy()
  ) {
    self.init(
      runtime: selection.resolve(),
      instructions: instructions,
      options: options,
      contextOptions: contextOptions,
      toolExecutionPolicy: toolExecutionPolicy
    )
    self.runtimeSelection = selection
  }

  public func generate(messages: [AgentMessage], tools: [any CoreAgent.Tool]) async throws -> ModelOutput {
    let runtime = activeRuntime()
    try runtime.validateAvailability()

    let audit = FoundationModelToolAudit()
    let prompt = FoundationModelPrompt.makePrompt(messages: messages)
    let foundationTools = try tools.map {
      try FoundationModelToolAdapter(
        tool: $0,
        toolExecutionPolicy: toolExecutionPolicy,
        task: prompt,
        audit: audit
      )
    }
    let session = runtime.makeSession(
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await runtime.tokenCount(for: prompt)
    let toolDefinitionTokens = try await runtime.tokenCount(for: foundationTools)
    let response: LanguageModelSession.Response<String>
    do {
      response = try await session.respond(to: prompt, options: options, contextOptions: contextOptions)
    } catch {
      try await throwToolExecutionErrorIfNeeded(error, audit: audit, session: session, tools: tools)
      throw error
    }
    return .finalAnswer(
      response.content,
      events: try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools),
      usage: AgentUsage(
        inputTokens: inputTokens,
        outputTokens: try await runtime.tokenCount(for: response.content),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  public func generate(
    prompt: Prompt,
    taskDescription: String? = nil,
    tools: [any CoreAgent.Tool] = []
  ) async throws -> ModelOutput {
    try await generate(
      prompt: prompt,
      toolTaskDescription: taskDescription ?? String(describing: prompt),
      tools: tools
    )
  }

  public func stream(
    messages: [AgentMessage],
    tools: [any CoreAgent.Tool],
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelOutput {
    let runtime = activeRuntime()
    try runtime.validateAvailability()

    let audit = FoundationModelToolAudit()
    let prompt = FoundationModelPrompt.makePrompt(messages: messages)
    let foundationTools = try tools.map {
      try FoundationModelToolAdapter(
        tool: $0,
        toolExecutionPolicy: toolExecutionPolicy,
        task: prompt,
        audit: audit
      )
    }
    let session = runtime.makeSession(
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await runtime.tokenCount(for: prompt)
    let toolDefinitionTokens = try await runtime.tokenCount(for: foundationTools)
    var finalContent = ""

    do {
      for try await partialResponse in session.streamResponse(
        to: prompt,
        options: options,
        contextOptions: contextOptions
      ) {
        finalContent = partialResponse.content
        await onPartialResponse(partialResponse.content)
      }
    } catch {
      try await throwToolExecutionErrorIfNeeded(error, audit: audit, session: session, tools: tools)
      throw error
    }

    return .finalAnswer(
      finalContent,
      events: try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools),
      usage: AgentUsage(
        inputTokens: inputTokens,
        outputTokens: try await runtime.tokenCount(for: finalContent),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  public func stream(
    prompt: Prompt,
    taskDescription: String? = nil,
    tools: [any CoreAgent.Tool] = [],
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelOutput {
    try await stream(
      prompt: prompt,
      toolTaskDescription: taskDescription ?? String(describing: prompt),
      tools: tools,
      onPartialResponse: onPartialResponse
    )
  }

  public func generateStructuredContent(
    prompt: String,
    schemaName: String,
    schemaDescription: String? = nil,
    properties: [String: ToolInput],
    includeSchemaInPrompt: Bool? = nil
  ) async throws -> String {
    let runtime = activeRuntime()
    try runtime.validateAvailability()

    let root = try FoundationModelSchemaAdapter.makeObjectSchema(
      name: schemaName,
      description: schemaDescription,
      properties: properties
    )
    let schema = try GenerationSchema(root: root, dependencies: [])
    let session = runtime.makeSession(instructions: instructions)
    let structuredContextOptions = ContextOptions(
      includeSchemaInPrompt: includeSchemaInPrompt ?? contextOptions.includeSchemaInPrompt ?? true,
      reasoningLevel: contextOptions.reasoningLevel
    )
    let response = try await session.respond(
      to: prompt,
      schema: schema,
      options: options,
      contextOptions: structuredContextOptions
    )
    return response.content.jsonString
  }

  private func activeRuntime() -> FoundationModelRuntime {
    runtimeSelection?.resolve() ?? runtime
  }

  private func generate(
    prompt: Prompt,
    toolTaskDescription: String,
    tools: [any CoreAgent.Tool]
  ) async throws -> ModelOutput {
    let runtime = activeRuntime()
    try runtime.validateAvailability()

    let audit = FoundationModelToolAudit()
    let foundationTools = try tools.map {
      try FoundationModelToolAdapter(
        tool: $0,
        toolExecutionPolicy: toolExecutionPolicy,
        task: toolTaskDescription,
        audit: audit
      )
    }
    let session = runtime.makeSession(
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await runtime.tokenCount(for: prompt)
    let toolDefinitionTokens = try await runtime.tokenCount(for: foundationTools)
    let response: LanguageModelSession.Response<String>
    do {
      response = try await session.respond(to: prompt, options: options, contextOptions: contextOptions)
    } catch {
      try await throwToolExecutionErrorIfNeeded(error, audit: audit, session: session, tools: tools)
      throw error
    }
    return .finalAnswer(
      response.content,
      events: try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools),
      usage: AgentUsage(
        inputTokens: inputTokens,
        outputTokens: try await runtime.tokenCount(for: response.content),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  private func stream(
    prompt: Prompt,
    toolTaskDescription: String,
    tools: [any CoreAgent.Tool],
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelOutput {
    let runtime = activeRuntime()
    try runtime.validateAvailability()

    let audit = FoundationModelToolAudit()
    let foundationTools = try tools.map {
      try FoundationModelToolAdapter(
        tool: $0,
        toolExecutionPolicy: toolExecutionPolicy,
        task: toolTaskDescription,
        audit: audit
      )
    }
    let session = runtime.makeSession(
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await runtime.tokenCount(for: prompt)
    let toolDefinitionTokens = try await runtime.tokenCount(for: foundationTools)
    var finalContent = ""

    do {
      for try await partialResponse in session.streamResponse(
        to: prompt,
        options: options,
        contextOptions: contextOptions
      ) {
        finalContent = partialResponse.content
        await onPartialResponse(partialResponse.content)
      }
    } catch {
      try await throwToolExecutionErrorIfNeeded(error, audit: audit, session: session, tools: tools)
      throw error
    }

    return .finalAnswer(
      finalContent,
      events: try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools),
      usage: AgentUsage(
        inputTokens: inputTokens,
        outputTokens: try await runtime.tokenCount(for: finalContent),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  private func throwToolExecutionErrorIfNeeded(
    _ error: any Error,
    audit: FoundationModelToolAudit,
    session: LanguageModelSession,
    tools: [any CoreAgent.Tool]
  ) async throws {
    let events = try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools)
    guard !events.isEmpty else {
      return
    }

    let description = events.reversed().lazy.compactMap { event in
      event.errorDescription ?? event.message
    }.first ?? String(describing: error)
    throw FoundationModelToolExecutionError(
      underlyingDescription: description,
      agentEvents: events
    )
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FoundationModelProvider: ToolExecutionPolicyConfigurableModelProvider {
  public func withToolExecutionPolicy(_ policy: any ToolExecutionPolicy) -> any ModelProvider {
    if let runtimeSelection {
      return FoundationModelProvider(
        selection: runtimeSelection,
        instructions: instructions,
        options: options,
        contextOptions: contextOptions,
        toolExecutionPolicy: policy
      )
    } else {
      return FoundationModelProvider(
        runtime: runtime,
        instructions: instructions,
        options: options,
        contextOptions: contextOptions,
        toolExecutionPolicy: policy
      )
    }
  }
}

public actor FoundationModelToolAudit {
  private var recordedEvents: [AgentEvent] = []

  public init() {}

  public func record(_ event: AgentEvent) {
    recordedEvents.append(event)
  }

  public func events() -> [AgentEvent] {
    recordedEvents
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
enum FoundationModelTranscriptEvents {
  static func makeEvents(from transcript: Transcript, tools: [any CoreAgent.Tool]) throws -> [AgentEvent] {
    let manifestsByName = try tools.reduce(into: [String: ToolManifest]()) { partialResult, tool in
      partialResult[tool.name] = try ToolManifest(tool: tool)
    }
    var events: [AgentEvent] = []

    for entry in transcript {
      switch entry {
      case .toolCalls(let toolCalls):
        events.append(
          contentsOf: toolCalls.map { toolCall in
            AgentEvent(
              kind: .toolCallStarted,
              message: "\(toolCall.toolName)(\(toolCall.arguments.jsonString))",
              toolCall: ToolCall(id: toolCall.id, name: toolCall.toolName),
              toolManifest: manifestsByName[toolCall.toolName]
            )
          }
        )
      case .toolOutput(let toolOutput):
        let output = toolOutput.segments.coreAgentJoinedText()
        events.append(
          AgentEvent(
            kind: .toolCallFinished,
            message: output,
            toolCall: ToolCall(id: toolOutput.id, name: toolOutput.toolName),
            toolResult: ToolResult(callID: toolOutput.id, output: output),
            toolManifest: manifestsByName[toolOutput.toolName]
          )
        )
      default:
        break
      }
    }

    return events
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
private extension [Transcript.Segment] {
  func coreAgentJoinedText() -> String {
    map { segment in
      switch segment {
      case .text(let text):
        text.content
      case .structure(let structure):
        structure.content.jsonString
      case .attachment:
        "[attachment]"
      case .custom(let custom):
        String(describing: custom)
      @unknown default:
        String(describing: segment)
      }
    }
    .joined(separator: "\n")
  }
}

enum FoundationModelPrompt {
  static func makePrompt(messages: [AgentMessage]) -> String {
    var lines: [String] = []

    for message in messages where message.role != .system {
      lines.append("\(message.role.rawValue.capitalized): \(message.content)")
    }

    return lines.joined(separator: "\n")
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelToolAdapter: FoundationModels.Tool {
  public typealias Arguments = GeneratedContent
  public typealias Output = String

  private let tool: any CoreAgent.Tool
  private let toolExecutionPolicy: any ToolExecutionPolicy
  private let task: String
  private let audit: FoundationModelToolAudit?
  public let parameters: GenerationSchema

  public init(
    tool: any CoreAgent.Tool,
    toolExecutionPolicy: any ToolExecutionPolicy = AllowAllToolExecutionPolicy(),
    task: String = "",
    audit: FoundationModelToolAudit? = nil
  ) throws {
    self.tool = tool
    self.toolExecutionPolicy = toolExecutionPolicy
    self.task = task
    self.audit = audit
    self.parameters = try FoundationModelSchemaAdapter.makeToolParameters(for: tool)
  }

  public var name: String { tool.name }
  public var description: String {
    guard let outputDescription = (tool as? any ToolOutputDescribing)?.outputDescription,
          !outputDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return tool.description
    }

    return "\(tool.description)\nReturns: \(outputDescription)"
  }

  @concurrent
  public func call(arguments: GeneratedContent) async throws -> String {
    let decodedArguments = try Self.decode(arguments, for: tool)
    let call = ToolCall(name: tool.name, arguments: decodedArguments)
    let manifest = try ToolManifest(tool: tool)
    do {
      try await toolExecutionPolicy.authorize(
        ToolExecutionContext(call: call, stepNumber: 0, task: task, toolManifest: manifest)
      )
      await audit?.record(
        AgentEvent(
          kind: .toolCallAuthorized,
          message: "Tool call authorized.",
          toolCall: call,
          toolManifest: manifest
        )
      )
    } catch {
      await audit?.record(
        AgentEvent(
          kind: .toolCallDenied,
          message: String(describing: error),
          errorType: String(reflecting: Swift.type(of: error)),
          errorDescription: String(describing: error),
          toolCall: call,
          toolManifest: manifest
        )
      )
      throw error
    }
    do {
      return try await tool.call(arguments: decodedArguments)
    } catch {
      await audit?.record(
        AgentEvent(
          kind: .toolCallFailed,
          message: String(describing: error),
          errorType: String(reflecting: Swift.type(of: error)),
          errorDescription: String(describing: error),
          toolCall: call,
          toolManifest: manifest
        )
      )
      throw error
    }
  }

  private static func decode(_ content: GeneratedContent, for tool: any CoreAgent.Tool) throws -> [String: String] {
    var arguments: [String: String] = [:]

    for (name, input) in tool.inputs {
      do {
        switch input.type {
        case .string:
          arguments[name] = try content.value(String.self, forProperty: name)
        case .integer:
          arguments[name] = String(try content.value(Int.self, forProperty: name))
        case .number:
          arguments[name] = String(try content.value(Double.self, forProperty: name))
        case .boolean:
          arguments[name] = String(try content.value(Bool.self, forProperty: name))
        case .object, .array:
          arguments[name] = try content.value(GeneratedContent.self, forProperty: name).jsonString
        case .any:
          throw FoundationModelProviderError.unsupportedToolInputType(input.type.rawValue)
        }
      } catch {
        if input.isRequired {
          throw FoundationModelProviderError.invalidToolArguments(tool: tool.name, message: "\(name): \(error)")
        }
      }
    }

    return arguments
  }
}

@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelSchemaAdapter {
  public static func makeToolParameters(for tool: any CoreAgent.Tool) throws -> GenerationSchema {
    let root = try makeObjectSchema(
      name: "\(tool.name)Arguments",
      description: "Arguments for \(tool.name).",
      properties: tool.inputs
    )
    return try GenerationSchema(root: root, dependencies: [])
  }

  public static func makeObjectSchema(
    name: String,
    description: String? = nil,
    properties: [String: ToolInput]
  ) throws -> DynamicGenerationSchema {
    let dynamicProperties = try properties
      .sorted(by: { $0.key < $1.key })
      .map { name, input in
        try DynamicGenerationSchema.Property(
          name: name,
          description: input.description,
          schema: dynamicSchema(for: input, nameHint: name.coreAgentSchemaName),
          isOptional: !input.isRequired
        )
      }

    return DynamicGenerationSchema(
      name: name.coreAgentSchemaName,
      description: description,
      properties: dynamicProperties
    )
  }

  public static func dynamicSchema(for input: ToolInput, nameHint: String = "Value") throws -> DynamicGenerationSchema {
    switch input.type {
    case .string:
      return DynamicGenerationSchema(type: String.self)
    case .integer:
      return DynamicGenerationSchema(type: Int.self)
    case .number:
      return DynamicGenerationSchema(type: Double.self)
    case .boolean:
      return DynamicGenerationSchema(type: Bool.self)
    case .object:
      guard !input.properties.isEmpty else {
        throw FoundationModelProviderError.invalidToolInputSchema("Object '\(nameHint)' must define properties.")
      }
      return try makeObjectSchema(
        name: nameHint,
        description: input.description,
        properties: input.properties
      )
    case .array:
      guard let items = input.items else {
        throw FoundationModelProviderError.invalidToolInputSchema("Array '\(nameHint)' must define an item schema.")
      }
      return try DynamicGenerationSchema(arrayOf: dynamicSchema(for: items, nameHint: "\(nameHint)Item"))
    case .any:
      throw FoundationModelProviderError.unsupportedToolInputType(input.type.rawValue)
    }
  }
}

private extension String {
  var coreAgentSchemaName: String {
    let parts = split { !$0.isLetter && !$0.isNumber }
    let name = parts.map { part in
      part.prefix(1).uppercased() + part.dropFirst()
    }.joined()
    return name.isEmpty ? "Schema" : name
  }
}
