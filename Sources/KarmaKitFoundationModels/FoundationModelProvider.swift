import Foundation
import FoundationModels
import KarmaKit

@available(iOS 26.0, macOS 26.0, *)
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelProvider: StreamingModelProvider {
  public var model: SystemLanguageModel
  public var instructions: String?
  public var options: GenerationOptions
  public var toolExecutionPolicy: any ToolExecutionPolicy

  public init(
    model: SystemLanguageModel = .default,
    instructions: String? = nil,
    options: GenerationOptions = GenerationOptions(),
    toolExecutionPolicy: any ToolExecutionPolicy = AllowAllToolExecutionPolicy()
  ) {
    self.model = model
    self.instructions = instructions
    self.options = options
    self.toolExecutionPolicy = toolExecutionPolicy
  }

  public func generate(messages: [AgentMessage], tools: [any KarmaKit.Tool]) async throws -> ModelOutput {
    try validateAvailability()

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
    let session = LanguageModelSession(
      model: model,
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await tokenCount(for: prompt)
    let toolDefinitionTokens = try await tokenCount(for: foundationTools)
    let response: LanguageModelSession.Response<String>
    do {
      response = try await session.respond(to: prompt, options: options)
    } catch {
      try await throwToolExecutionErrorIfNeeded(error, audit: audit, session: session, tools: tools)
      throw error
    }
    return .finalAnswer(
      response.content,
      events: try await audit.events() + FoundationModelTranscriptEvents.makeEvents(from: session.transcript, tools: tools),
      usage: AgentUsage(
        inputTokens: inputTokens,
        outputTokens: try await tokenCount(for: response.content),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  public func stream(
    messages: [AgentMessage],
    tools: [any KarmaKit.Tool],
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> ModelOutput {
    try validateAvailability()

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
    let session = LanguageModelSession(
      model: model,
      tools: foundationTools,
      instructions: instructions
    )

    let inputTokens = try await tokenCount(for: prompt)
    let toolDefinitionTokens = try await tokenCount(for: foundationTools)
    var finalContent = ""

    do {
      for try await partialResponse in session.streamResponse(to: prompt, options: options) {
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
        outputTokens: try await tokenCount(for: finalContent),
        toolDefinitionTokens: toolDefinitionTokens
      )
    )
  }

  public func generateStructuredContent(
    prompt: String,
    schemaName: String,
    schemaDescription: String? = nil,
    properties: [String: ToolInput],
    includeSchemaInPrompt: Bool = true
  ) async throws -> String {
    try validateAvailability()

    let root = try FoundationModelSchemaAdapter.makeObjectSchema(
      name: schemaName,
      description: schemaDescription,
      properties: properties
    )
    let schema = try GenerationSchema(root: root, dependencies: [])
    let session = LanguageModelSession(model: model, instructions: instructions)
    let response = try await session.respond(
      to: prompt,
      schema: schema,
      includeSchemaInPrompt: includeSchemaInPrompt,
      options: options
    )
    return response.content.jsonString
  }

  private func validateAvailability() throws {
    switch model.availability {
    case .available:
      return
    case .unavailable(let reason):
      throw FoundationModelProviderError.unavailable(String(describing: reason))
    }
  }

  private func tokenCount(for prompt: String) async throws -> Int? {
    if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
      return try await model.tokenCount(for: prompt)
    }

    return nil
  }

  private func tokenCount(for tools: [any FoundationModels.Tool]) async throws -> Int? {
    guard !tools.isEmpty else {
      return nil
    }

    if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
      return try await model.tokenCount(for: tools)
    }

    return nil
  }

  private func throwToolExecutionErrorIfNeeded(
    _ error: any Error,
    audit: FoundationModelToolAudit,
    session: LanguageModelSession,
    tools: [any KarmaKit.Tool]
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
extension FoundationModelProvider: ToolExecutionPolicyConfigurableModelProvider {
  public func withToolExecutionPolicy(_ policy: any ToolExecutionPolicy) -> any ModelProvider {
    FoundationModelProvider(
      model: model,
      instructions: instructions,
      options: options,
      toolExecutionPolicy: policy
    )
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
enum FoundationModelTranscriptEvents {
  static func makeEvents(from transcript: Transcript, tools: [any KarmaKit.Tool]) throws -> [AgentEvent] {
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
        let output = toolOutput.segments.karmaJoinedText()
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
private extension [Transcript.Segment] {
  func karmaJoinedText() -> String {
    map { segment in
      switch segment {
      case .text(let text):
        text.content
      case .structure(let structure):
        structure.content.jsonString
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelToolAdapter: FoundationModels.Tool {
  public typealias Arguments = GeneratedContent
  public typealias Output = String

  private let tool: any KarmaKit.Tool
  private let toolExecutionPolicy: any ToolExecutionPolicy
  private let task: String
  private let audit: FoundationModelToolAudit?
  public let parameters: GenerationSchema

  public init(
    tool: any KarmaKit.Tool,
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
  public var description: String { tool.description }

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
    return try await tool.call(arguments: decodedArguments)
  }

  private static func decode(_ content: GeneratedContent, for tool: any KarmaKit.Tool) throws -> [String: String] {
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

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelSchemaAdapter {
  public static func makeToolParameters(for tool: any KarmaKit.Tool) throws -> GenerationSchema {
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
          schema: dynamicSchema(for: input, nameHint: name.karmaSchemaName),
          isOptional: !input.isRequired
        )
      }

    return DynamicGenerationSchema(
      name: name.karmaSchemaName,
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
  var karmaSchemaName: String {
    let parts = split { !$0.isLetter && !$0.isNumber }
    let name = parts.map { part in
      part.prefix(1).uppercased() + part.dropFirst()
    }.joined()
    return name.isEmpty ? "Schema" : name
  }
}
