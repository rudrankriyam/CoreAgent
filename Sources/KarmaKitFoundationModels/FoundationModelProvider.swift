import Foundation
import FoundationModels
import KarmaKit

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelProviderError: Error, CustomStringConvertible, Equatable, Sendable {
  case unavailable(String)
  case unsupportedToolInputType(String)
  case invalidToolArguments(tool: String, message: String)

  public var description: String {
    switch self {
    case .unavailable(let reason):
      return "Foundation Models is unavailable: \(reason)"
    case .unsupportedToolInputType(let type):
      return "Foundation Models does not support tool input type '\(type)' yet."
    case .invalidToolArguments(let tool, let message):
      return "Invalid arguments for tool '\(tool)': \(message)"
    }
  }
}

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public struct FoundationModelProvider: ModelProvider {
  public var model: SystemLanguageModel
  public var instructions: String?
  public var options: GenerationOptions

  public init(
    model: SystemLanguageModel = .default,
    instructions: String? = nil,
    options: GenerationOptions = GenerationOptions()
  ) {
    self.model = model
    self.instructions = instructions
    self.options = options
  }

  public func generate(messages: [AgentMessage], tools: [any KarmaKit.Tool]) async throws -> ModelOutput {
    try validateAvailability()

    let foundationTools = try tools.map { try FoundationModelToolAdapter(tool: $0) }
    let session = LanguageModelSession(
      model: model,
      tools: foundationTools,
      instructions: instructions
    )

    let prompt = FoundationModelPrompt.makePrompt(messages: messages)
    let response = try await session.respond(to: prompt, options: options)
    return .finalAnswer(response.content)
  }

  private func validateAvailability() throws {
    switch model.availability {
    case .available:
      return
    case .unavailable(let reason):
      throw FoundationModelProviderError.unavailable(String(describing: reason))
    }
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
  public let parameters: GenerationSchema

  public init(tool: any KarmaKit.Tool) throws {
    self.tool = tool
    self.parameters = try Self.makeParameters(for: tool)
  }

  public var name: String { tool.name }
  public var description: String { tool.description }

  @concurrent
  public func call(arguments: GeneratedContent) async throws -> String {
    let decodedArguments = try Self.decode(arguments, for: tool)
    return try await tool.call(arguments: decodedArguments)
  }

  private static func makeParameters(for tool: any KarmaKit.Tool) throws -> GenerationSchema {
    let properties = try tool.inputs
      .sorted(by: { $0.key < $1.key })
      .map { name, input in
        try DynamicGenerationSchema.Property(
          name: name,
          description: input.description,
          schema: dynamicSchema(for: input),
          isOptional: !input.isRequired
        )
      }

    let root = DynamicGenerationSchema(
      name: "\(tool.name)Arguments",
      description: "Arguments for \(tool.name).",
      properties: properties
    )
    return try GenerationSchema(root: root, dependencies: [])
  }

  private static func dynamicSchema(for input: ToolInput) throws -> DynamicGenerationSchema {
    switch input.type {
    case .string:
      return DynamicGenerationSchema(type: String.self)
    case .integer:
      return DynamicGenerationSchema(type: Int.self)
    case .number:
      return DynamicGenerationSchema(type: Double.self)
    case .boolean:
      return DynamicGenerationSchema(type: Bool.self)
    case .object, .array, .any:
      throw FoundationModelProviderError.unsupportedToolInputType(input.type.rawValue)
    }
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
        case .object, .array, .any:
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
