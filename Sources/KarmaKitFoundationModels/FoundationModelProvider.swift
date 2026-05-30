import Foundation
import FoundationModels
import KarmaKit

@available(iOS 26.0, macOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum FoundationModelProviderError: Error, CustomStringConvertible, Equatable, Sendable {
  case unavailable(String)

  public var description: String {
    switch self {
    case .unavailable(let reason):
      return "Foundation Models is unavailable: \(reason)"
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

    let session = LanguageModelSession(
      model: model,
      instructions: instructions
    )

    let prompt = FoundationModelPrompt.makePrompt(messages: messages, tools: tools)
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
  static func makePrompt(messages: [AgentMessage], tools: [any KarmaKit.Tool]) -> String {
    var lines: [String] = []

    for message in messages where message.role != .system {
      lines.append("\(message.role.rawValue.capitalized): \(message.content)")
    }

    if !tools.isEmpty {
      lines.append("")
      lines.append("Available actions:")

      for tool in tools.sorted(by: { $0.name < $1.name }) {
        lines.append("- \(tool.name): \(tool.description)")

        if !tool.inputs.isEmpty {
          let inputSummary = tool.inputs
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key) (\($0.value.type.rawValue)): \($0.value.description)" }
            .joined(separator: "; ")
          lines.append("  Inputs: \(inputSummary)")
        }
      }
    }

    return lines.joined(separator: "\n")
  }
}
