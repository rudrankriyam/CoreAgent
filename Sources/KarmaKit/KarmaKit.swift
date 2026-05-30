import Foundation

public enum KarmaError: Error, Equatable, Sendable {
  case missingTool(String)
  case invalidToolArguments(tool: String, expected: [String])
  case maxStepsReached(Int)
}

public enum MessageRole: String, Codable, Equatable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public struct AgentMessage: Codable, Equatable, Sendable {
  public var role: MessageRole
  public var content: String
  public var toolCallID: String?

  public init(role: MessageRole, content: String, toolCallID: String? = nil) {
    self.role = role
    self.content = content
    self.toolCallID = toolCallID
  }
}

public struct ToolInput: Codable, Equatable, Sendable {
  public enum ValueType: String, Codable, Equatable, Sendable {
    case string
    case integer
    case number
    case boolean
    case object
    case array
    case any
  }

  public var type: ValueType
  public var description: String
  public var isRequired: Bool

  public init(type: ValueType, description: String, isRequired: Bool = true) {
    self.type = type
    self.description = description
    self.isRequired = isRequired
  }
}

public struct ToolCall: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var arguments: [String: String]

  public init(id: String = UUID().uuidString, name: String, arguments: [String: String] = [:]) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ToolResult: Codable, Equatable, Sendable {
  public var callID: String
  public var output: String

  public init(callID: String, output: String) {
    self.callID = callID
    self.output = output
  }
}

public protocol Tool: Sendable {
  var name: String { get }
  var description: String { get }
  var inputs: [String: ToolInput] { get }

  func call(arguments: [String: String]) async throws -> String
}

public struct ClosureTool: Tool {
  public var name: String
  public var description: String
  public var inputs: [String: ToolInput]
  private let handler: @Sendable ([String: String]) async throws -> String

  public init(
    name: String,
    description: String,
    inputs: [String: ToolInput],
    handler: @escaping @Sendable ([String: String]) async throws -> String
  ) {
    self.name = name
    self.description = description
    self.inputs = inputs
    self.handler = handler
  }

  public func call(arguments: [String: String]) async throws -> String {
    let missingRequiredInputs = inputs
      .filter { $0.value.isRequired && arguments[$0.key] == nil }
      .map(\.key)

    guard missingRequiredInputs.isEmpty else {
      throw KarmaError.invalidToolArguments(tool: name, expected: missingRequiredInputs.sorted())
    }

    return try await handler(arguments)
  }
}

public enum ModelOutput: Equatable, Sendable {
  case toolCalls([ToolCall])
  case finalAnswer(String)
}

public protocol ModelProvider: Sendable {
  func generate(messages: [AgentMessage], tools: [any Tool]) async throws -> ModelOutput
}

public struct ActionStep: Equatable, Sendable {
  public var stepNumber: Int
  public var modelOutput: ModelOutput
  public var toolResults: [ToolResult]
  public var isFinalAnswer: Bool

  public init(
    stepNumber: Int,
    modelOutput: ModelOutput,
    toolResults: [ToolResult] = [],
    isFinalAnswer: Bool = false
  ) {
    self.stepNumber = stepNumber
    self.modelOutput = modelOutput
    self.toolResults = toolResults
    self.isFinalAnswer = isFinalAnswer
  }
}

public struct AgentMemory: Sendable {
  public private(set) var systemPrompt: String
  public private(set) var messages: [AgentMessage]
  public private(set) var steps: [ActionStep]

  public init(systemPrompt: String) {
    self.systemPrompt = systemPrompt
    self.messages = [.init(role: .system, content: systemPrompt)]
    self.steps = []
  }

  public mutating func addTask(_ task: String) {
    messages.append(.init(role: .user, content: task))
  }

  public mutating func addAssistantMessage(_ content: String) {
    messages.append(.init(role: .assistant, content: content))
  }

  public mutating func addToolResult(_ result: ToolResult) {
    messages.append(.init(role: .tool, content: result.output, toolCallID: result.callID))
  }

  public mutating func addStep(_ step: ActionStep) {
    steps.append(step)
  }
}

public struct AgentRun: Equatable, Sendable {
  public var finalAnswer: String
  public var steps: [ActionStep]
  public var messages: [AgentMessage]

  public init(finalAnswer: String, steps: [ActionStep], messages: [AgentMessage]) {
    self.finalAnswer = finalAnswer
    self.steps = steps
    self.messages = messages
  }
}

public final class ToolCallingAgent: @unchecked Sendable {
  public let model: any ModelProvider
  public let tools: [String: any Tool]
  public let maxSteps: Int
  public private(set) var memory: AgentMemory

  public init(
    tools: [any Tool],
    model: any ModelProvider,
    systemPrompt: String = "You are a helpful Swift agent. Use tools when useful, then return a final answer.",
    maxSteps: Int = 8
  ) {
    self.model = model
    self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    self.maxSteps = maxSteps
    self.memory = AgentMemory(systemPrompt: systemPrompt)
  }

  public func run(_ task: String) async throws -> AgentRun {
    memory.addTask(task)

    for stepNumber in 1...maxSteps {
      let output = try await model.generate(messages: memory.messages, tools: Array(tools.values))

      switch output {
      case .finalAnswer(let answer):
        memory.addAssistantMessage(answer)
        memory.addStep(.init(stepNumber: stepNumber, modelOutput: output, isFinalAnswer: true))
        return AgentRun(finalAnswer: answer, steps: memory.steps, messages: memory.messages)

      case .toolCalls(let calls):
        let results = try await calls.asyncMap { call in
          guard let tool = tools[call.name] else {
            throw KarmaError.missingTool(call.name)
          }

          let output = try await tool.call(arguments: call.arguments)
          return ToolResult(callID: call.id, output: output)
        }

        for result in results {
          memory.addToolResult(result)
        }

        memory.addStep(.init(stepNumber: stepNumber, modelOutput: output, toolResults: results))
      }
    }

    throw KarmaError.maxStepsReached(maxSteps)
  }
}

public struct ScriptedModel: ModelProvider {
  private let store: ScriptedModelStore

  public init(outputs: [ModelOutput], fallback: ModelOutput = .finalAnswer("")) {
    self.store = ScriptedModelStore(outputs: outputs, fallback: fallback)
  }

  public func generate(messages: [AgentMessage], tools: [any Tool]) async throws -> ModelOutput {
    await store.next()
  }
}

private actor ScriptedModelStore {
  private let outputs: [ModelOutput]
  private let fallback: ModelOutput
  private var index: Int = 0

  init(outputs: [ModelOutput], fallback: ModelOutput) {
    self.outputs = outputs
    self.fallback = fallback
  }

  func next() -> ModelOutput {
    guard outputs.indices.contains(index) else {
      return fallback
    }

    let output = outputs[index]
    index += 1
    return output
  }
}

private extension Sequence {
  func asyncMap<T>(_ transform: (Element) async throws -> T) async throws -> [T] {
    var values: [T] = []
    for element in self {
      try await values.append(transform(element))
    }
    return values
  }
}
