import Foundation
import FoundationModels
import CoreAgent
import CoreAgentFoundationModels
import CoreAgentTools

@main
struct CoreAgentCLI {
  static func main() async {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())

      guard !arguments.isEmpty else {
        printUsage()
        return
      }

      let listsTools = arguments.removeAll("--list-tools")
      let printsConfiguration = arguments.removeAll("--print-config")
      let printsDiscovery = arguments.removeAll("--print-discovery")
      let enablesDemoTools = arguments.removeAll("--demo-tools")
      let enablesVerboseOutput = arguments.removeAll("--verbose")
      let enablesStreaming = arguments.removeAll("--stream")
      let enablesStructuredDemo = arguments.removeAll("--structured-demo")
      let enablesParallelTools = arguments.removeAll("--parallel-tools")
      let enablesActionOnly = arguments.removeAll("--action-only")
      let usesPrivateCloudCompute = arguments.removeAll("--pcc")
      let prefersPrivateCloudCompute = arguments.removeAll("--prefer-pcc")
      let printsModelInfo = arguments.removeAll("--print-model-info")
      let failsOnToolArgumentError = arguments.removeAll("--fail-on-tool-argument-error")
      let failsOnFinalAnswerRejection = arguments.removeAll("--fail-on-final-answer-rejection")
      let disablesRedaction = arguments.removeAll("--no-redaction")
      let tracePath = arguments.removeOptionValue("--trace")
      let receiptPath = arguments.removeOptionValue("--receipt")
      let receiptVerificationPath = arguments.removeOptionValue("--verify-receipt")
      let traceVerificationPath = arguments.removeOptionValue("--verify-trace")
      let maximumModelInputCharacters = arguments.removeOptionValue("--max-model-input-chars").flatMap(Int.init)
      let maximumToolOutputCharacters = arguments.removeOptionValue("--max-tool-output-chars").flatMap(Int.init)
      let maximumContextMessages = arguments.removeOptionValue("--max-context-messages").flatMap(Int.init)
      let maximumMemoryMessages = arguments.removeOptionValue("--max-memory-messages").flatMap(Int.init)
      let maximumResponseTokens = arguments.removeOptionValue("--max-response-tokens").flatMap(Int.init)
      let temperature = arguments.removeOptionValue("--temperature").flatMap(Double.init)
      let reasoningLevel = arguments.removeOptionValue("--reasoning").map(parseReasoningLevel)
      let toolCallingMode = arguments.removeOptionValue("--tool-calling").map(parseToolCallingMode)
      let modelTimeoutSeconds = arguments.removeOptionValue("--model-timeout-seconds").flatMap(Double.init)
      let runTimeoutSeconds = arguments.removeOptionValue("--run-timeout-seconds").flatMap(Double.init)
      let allowedFileDirectories = arguments.removeOptionValues("--allow-file-dir")
      let allowedURLHosts = arguments.removeOptionValues("--allow-url-host")
      let deniedToolNames = Set(arguments.removeOptionValues("--deny-tool"))
      let prompt = arguments.joined(separator: " ")
      let tools = makeTools(
        enablesDemoTools: enablesDemoTools,
        enablesActionOnly: enablesActionOnly,
        allowedFileDirectories: allowedFileDirectories,
        allowedURLHosts: allowedURLHosts
      )
      let redactionPolicy: AgentRedactionPolicy = disablesRedaction ? .none : .standard
      let completionMode: AgentCompletionMode = enablesActionOnly ? .actionOnly(doneToolName: "done") : .finalAnswer
      let timeouts = AgentTimeouts(
        modelGeneration: modelTimeoutSeconds.map(Duration.seconds),
        run: runTimeoutSeconds.map(Duration.seconds)
      )

      if let receiptVerificationPath {
        try verifyReceipt(
          receiptPath: receiptVerificationPath,
          tracePath: traceVerificationPath,
          redactionPolicy: redactionPolicy
        )
        return
      }

      if listsTools {
        try printToolManifests(for: tools, redactionPolicy: redactionPolicy)
        return
      }

      if printsConfiguration {
        try printAgentConfiguration(
          tools: tools,
          maximumModelInputCharacters: maximumModelInputCharacters,
          maximumToolOutputCharacters: maximumToolOutputCharacters,
          maximumContextMessages: maximumContextMessages,
          maximumMemoryMessages: maximumMemoryMessages,
          timeouts: timeouts,
          toolCallExecutionMode: enablesParallelTools ? .parallel : .sequential,
          toolArgumentErrorRecoveryMode: failsOnToolArgumentError ? .fail : .recover,
          finalAnswerRecoveryMode: failsOnFinalAnswerRejection ? .fail : .recover,
          completionMode: completionMode,
          redactionPolicy: redactionPolicy
        )
        return
      }

      if printsDiscovery {
        try printAgentDiscovery(
          tools: tools,
          maximumModelInputCharacters: maximumModelInputCharacters,
          maximumToolOutputCharacters: maximumToolOutputCharacters,
          maximumContextMessages: maximumContextMessages,
          maximumMemoryMessages: maximumMemoryMessages,
          timeouts: timeouts,
          toolCallExecutionMode: enablesParallelTools ? .parallel : .sequential,
          toolArgumentErrorRecoveryMode: failsOnToolArgumentError ? .fail : .recover,
          finalAnswerRecoveryMode: failsOnFinalAnswerRejection ? .fail : .recover,
          completionMode: completionMode,
          redactionPolicy: redactionPolicy
        )
        return
      }

      let runtimeSelection: FoundationModelRuntimeSelection = if usesPrivateCloudCompute {
        .privateCloudCompute()
      } else if prefersPrivateCloudCompute {
        .preferPrivateCloudCompute()
      } else {
        .system()
      }
      let provider = FoundationModelProvider(
        selection: runtimeSelection,
        instructions: "Answer clearly and concisely. You are running inside CoreAgent.",
        options: GenerationOptions(
          samplingMode: nil,
          temperature: temperature,
          maximumResponseTokens: maximumResponseTokens,
          toolCallingMode: toolCallingMode ?? (enablesActionOnly ? .required : nil)
        ),
        contextOptions: ContextOptions(reasoningLevel: reasoningLevel)
      )
      if printsModelInfo {
        try await printModelInfo(provider)
        return
      }
      if enablesStructuredDemo {
        let output = try await provider.generateStructuredContent(
          prompt: prompt,
          schemaName: "CoreAgentStructuredDemo",
          schemaDescription: "A concise structured response.",
          properties: [
            "title": ToolInput(type: .string, description: "A short title."),
            "summary": ToolInput(type: .string, description: "One sentence summary."),
            "tags": .array(
              description: "Two to four lowercase tags.",
              items: ToolInput(type: .string, description: "A tag.")
            )
          ]
        )
        print(output)
        return
      }

      let agent = try ToolCallingAgent(
        tools: tools,
        model: provider,
        toolExecutionPolicy: deniedToolNames.isEmpty
          ? AllowAllToolExecutionPolicy()
          : DenyNamedToolsPolicy(deniedToolNames: deniedToolNames),
        retryPolicy: RetryPolicy(maximumRetries: 1, delay: .milliseconds(200)),
        timeouts: timeouts,
        limits: AgentLimits(
          maximumModelInputCharacters: maximumModelInputCharacters,
          maximumToolOutputCharacters: maximumToolOutputCharacters,
          maximumContextMessages: maximumContextMessages,
          maximumMemoryMessages: maximumMemoryMessages
        ),
        toolCallExecutionMode: enablesParallelTools ? .parallel : .sequential,
        toolArgumentErrorRecoveryMode: failsOnToolArgumentError ? .fail : .recover,
        finalAnswerRecoveryMode: failsOnFinalAnswerRejection ? .fail : .recover,
        completionMode: completionMode,
        validatesToolNames: true
      )
      let startedAt = Date()
      let run: AgentRun
      do {
        if enablesStreaming {
          run = try await agent.runStreaming(prompt) { partial in
            print("\r\(partial)", terminator: "")
            fflush(stdout)
          }
          print("")
        } else {
          run = try await agent.run(prompt)
          print(run.finalAnswer)
        }
      } catch {
        let failedRun = agent.snapshotRun(startedAt: startedAt)
        try writeArtifacts(
          run: failedRun,
          tracePath: tracePath,
          receiptPath: receiptPath,
          redactionPolicy: redactionPolicy
        )
        if enablesVerboseOutput {
          fputs("\n\(failedRun.events.coreAgentDebugDescription)\n", stderr)
        }
        throw error
      }

      if enablesVerboseOutput {
        fputs("\n\(run.events.coreAgentDebugDescription)\n", stderr)
      }
      try writeArtifacts(
        run: run,
        tracePath: tracePath,
        receiptPath: receiptPath,
        redactionPolicy: redactionPolicy
      )
    } catch {
      fputs("\(error)\n", stderr)
      Foundation.exit(1)
    }
  }

  private static func printUsage() {
    print("Usage: core-agent <prompt>")
    print("       core-agent --demo-tools <prompt>")
    print("       core-agent --demo-tools --list-tools")
    print("       core-agent --demo-tools --print-config")
    print("       core-agent --demo-tools --print-discovery")
    print("       core-agent --verbose --demo-tools <prompt>")
    print("       core-agent --stream <prompt>")
    print("       core-agent --parallel-tools --demo-tools <prompt>")
    print("       core-agent --action-only --demo-tools <prompt>")
    print("       core-agent --pcc <prompt>")
    print("       core-agent --prefer-pcc <prompt>")
    print("       core-agent --print-model-info")
    print("       core-agent --reasoning deep <prompt>")
    print("       core-agent --tool-calling required --demo-tools <prompt>")
    print("       core-agent --temperature 0.8 --max-response-tokens 512 <prompt>")
    print("       core-agent --fail-on-tool-argument-error --demo-tools <prompt>")
    print("       core-agent --fail-on-final-answer-rejection --demo-tools <prompt>")
    print("       core-agent --trace /tmp/core-agent-trace.json <prompt>")
    print("       core-agent --receipt /tmp/core-agent-receipt.json <prompt>")
    print("       core-agent --verify-receipt /tmp/core-agent-receipt.json")
    print("       core-agent --verify-receipt /tmp/core-agent-receipt.json --verify-trace /tmp/core-agent-trace.json")
    print("       core-agent --no-redaction --trace /tmp/core-agent-trace.json <prompt>")
    print("       core-agent --max-model-input-chars 12000 <prompt>")
    print("       core-agent --max-tool-output-chars 4000 --demo-tools <prompt>")
    print("       core-agent --max-context-messages 12 --demo-tools <prompt>")
    print("       core-agent --max-memory-messages 40 --demo-tools <prompt>")
    print("       core-agent --model-timeout-seconds 30 <prompt>")
    print("       core-agent --run-timeout-seconds 60 <prompt>")
    print("       core-agent --demo-tools --deny-tool calculate <prompt>")
    print("       core-agent --structured-demo <prompt>")
    print("       core-agent --demo-tools --allow-file-dir /tmp <prompt>")
    print("       core-agent --demo-tools --allow-url-host example.com <prompt>")
    print("Example: core-agent Summarize tool calling in one sentence")
  }

  private static func parseReasoningLevel(_ value: String) -> ContextOptions.ReasoningLevel {
    switch value.lowercased() {
    case "light":
      .light
    case "moderate":
      .moderate
    case "deep":
      .deep
    default:
      .custom(value)
    }
  }

  private static func parseToolCallingMode(_ value: String) -> GenerationOptions.ToolCallingMode {
    switch value.lowercased() {
    case "required":
      .required
    case "disallowed":
      .disallowed
    default:
      .allowed
    }
  }

  private static func printModelInfo(_ provider: FoundationModelProvider) async throws {
    let snapshot = await provider.runtimeSnapshot()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let resetDate = snapshot.privateCloudComputeQuota?.resetDate {
      encoder.dateEncodingStrategy = .iso8601
      _ = resetDate
    }
    let data = try encoder.encode(snapshot)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func makeTools(
    enablesDemoTools: Bool,
    enablesActionOnly: Bool,
    allowedFileDirectories: [String],
    allowedURLHosts: [String]
  ) -> [any CoreAgent.Tool] {
    var tools: [any CoreAgent.Tool] = enablesDemoTools
      ? DemoTools.makeTools(allowedFileDirectories: allowedFileDirectories)
      : []
    if !allowedURLHosts.isEmpty {
      tools.append(URLFetchTool(allowedHosts: Set(allowedURLHosts)))
    }
    if enablesActionOnly {
      tools.append(ActionCompletionTool())
    }
    return tools
  }

  private static func printToolManifests(for tools: [any CoreAgent.Tool], redactionPolicy: AgentRedactionPolicy) throws {
    let manifests = try tools.map { try ToolManifest(tool: $0).redacted(using: redactionPolicy) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifests)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func writeArtifacts(
    run: AgentRun,
    tracePath: String?,
    receiptPath: String?,
    redactionPolicy: AgentRedactionPolicy
  ) throws {
    if let tracePath {
      try AgentTraceExporter(redactionPolicy: redactionPolicy).write(run, to: URL(fileURLWithPath: tracePath))
      fputs("Trace written to \(tracePath)\n", stderr)
    }
    if let receiptPath {
      try AgentReceiptExporter(redactionPolicy: redactionPolicy).write(run, to: URL(fileURLWithPath: receiptPath))
      fputs("Receipt written to \(receiptPath)\n", stderr)
    }
  }

  private static func verifyReceipt(
    receiptPath: String,
    tracePath: String?,
    redactionPolicy: AgentRedactionPolicy
  ) throws {
    let receiptExporter = AgentReceiptExporter(redactionPolicy: redactionPolicy)
    let receipt = try receiptExporter.read(from: URL(fileURLWithPath: receiptPath))
    let run: AgentRun?
    if let tracePath {
      let envelope = try AgentTraceExporter(redactionPolicy: redactionPolicy).read(from: URL(fileURLWithPath: tracePath))
      run = envelope.run.redacted(using: redactionPolicy)
    } else {
      run = nil
    }

    guard try receiptExporter.verify(receipt, for: run) else {
      throw CoreAgentCLIError.receiptVerificationFailed
    }

    if tracePath == nil {
      print("Receipt verified.")
    } else {
      print("Receipt and trace verified.")
    }
  }

  private static func printAgentConfiguration(
    tools: [any CoreAgent.Tool],
    maximumModelInputCharacters: Int?,
    maximumToolOutputCharacters: Int?,
    maximumContextMessages: Int?,
    maximumMemoryMessages: Int?,
    timeouts: AgentTimeouts,
    toolCallExecutionMode: ToolCallExecutionMode,
    toolArgumentErrorRecoveryMode: ToolArgumentErrorRecoveryMode,
    finalAnswerRecoveryMode: FinalAnswerRecoveryMode,
    completionMode: AgentCompletionMode,
    redactionPolicy: AgentRedactionPolicy
  ) throws {
    let configuration = AgentConfiguration(
      systemPrompt: "You are a helpful Swift agent. Use tools when useful, then return a final answer.",
      maxSteps: 8,
      resetsMemoryBeforeRun: true,
      retryPolicy: RetryPolicy(maximumRetries: 1, delay: .milliseconds(200)),
      timeouts: timeouts,
      limits: AgentLimits(
        maximumModelInputCharacters: maximumModelInputCharacters,
        maximumToolOutputCharacters: maximumToolOutputCharacters,
        maximumContextMessages: maximumContextMessages,
        maximumMemoryMessages: maximumMemoryMessages
      ),
      toolCallExecutionMode: toolCallExecutionMode,
      toolArgumentErrorRecoveryMode: toolArgumentErrorRecoveryMode,
      finalAnswerRecoveryMode: finalAnswerRecoveryMode,
      completionMode: completionMode,
      toolManifests: try tools.map(ToolManifest.init(tool:)).sorted { $0.name < $1.name }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration.redacted(using: redactionPolicy))
    print(String(decoding: data, as: UTF8.self))
  }

  private static func printAgentDiscovery(
    tools: [any CoreAgent.Tool],
    maximumModelInputCharacters: Int?,
    maximumToolOutputCharacters: Int?,
    maximumContextMessages: Int?,
    maximumMemoryMessages: Int?,
    timeouts: AgentTimeouts,
    toolCallExecutionMode: ToolCallExecutionMode,
    toolArgumentErrorRecoveryMode: ToolArgumentErrorRecoveryMode,
    finalAnswerRecoveryMode: FinalAnswerRecoveryMode,
    completionMode: AgentCompletionMode,
    redactionPolicy: AgentRedactionPolicy
  ) throws {
    let configuration = AgentConfiguration(
      systemPrompt: "You are a helpful Swift agent. Use tools when useful, then return a final answer.",
      maxSteps: 8,
      resetsMemoryBeforeRun: true,
      retryPolicy: RetryPolicy(maximumRetries: 1, delay: .milliseconds(200)),
      timeouts: timeouts,
      limits: AgentLimits(
        maximumModelInputCharacters: maximumModelInputCharacters,
        maximumToolOutputCharacters: maximumToolOutputCharacters,
        maximumContextMessages: maximumContextMessages,
        maximumMemoryMessages: maximumMemoryMessages
      ),
      toolCallExecutionMode: toolCallExecutionMode,
      toolArgumentErrorRecoveryMode: toolArgumentErrorRecoveryMode,
      finalAnswerRecoveryMode: finalAnswerRecoveryMode,
      completionMode: completionMode,
      toolManifests: try tools.map(ToolManifest.init(tool:)).sorted { $0.name < $1.name }
    )
    let document = AgentDiscoveryDocument(
      id: "com.rudrankriyam.coreagent.cli",
      name: "CoreAgent CLI Agent",
      description: "Local Swift agent powered by CoreAgent.",
      capabilities: completionMode.doneToolName == nil
        ? ["foundation-models", "trace-export", "receipt-export"]
        : ["foundation-models", "trace-export", "receipt-export", "action-only"],
      tags: ["swift", "local-first", "apple-platforms"],
      endpoints: [
        AgentEndpoint(name: "cli", transport: "stdio")
      ],
      configuration: configuration
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document.redacted(using: redactionPolicy))
    print(String(decoding: data, as: UTF8.self))
  }
}

private enum DemoTools {
  static func makeTools(allowedFileDirectories: [String]) -> [any CoreAgent.Tool] {
    var tools: [any CoreAgent.Tool] = [
      CurrentTimeTool(),
      MathTool()
    ]

    if !allowedFileDirectories.isEmpty {
      let allowedURLs = allowedFileDirectories.map {
        URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
      }
      tools.append(
        FileReadTool(
          allowedDirectories: allowedURLs
        )
      )
      tools.append(SearchFilesTool(allowedDirectories: allowedURLs))
    }

    return tools
  }
}

private struct DenyNamedToolsPolicy: ToolExecutionPolicy {
  var deniedToolNames: Set<String>

  func authorize(_ context: ToolExecutionContext) async throws {
    if deniedToolNames.contains(context.call.name) {
      throw CoreAgentCLIError.toolDenied(context.call.name)
    }
  }
}

private enum CoreAgentCLIError: Error, CustomStringConvertible {
  case receiptVerificationFailed
  case toolDenied(String)

  var description: String {
    switch self {
    case .receiptVerificationFailed:
      "Receipt verification failed."
    case .toolDenied(let name):
      "Tool '\(name)' was denied by CLI policy."
    }
  }
}

private extension Array where Element == String {
  mutating func removeAll(_ value: String) -> Bool {
    let originalCount = count
    self = filter { $0 != value }
    return count != originalCount
  }

  mutating func removeOptionValue(_ name: String) -> String? {
    guard let index = firstIndex(of: name) else {
      return nil
    }

    remove(at: index)
    guard indices.contains(index) else {
      return nil
    }

    return remove(at: index)
  }

  mutating func removeOptionValues(_ name: String) -> [String] {
    var values: [String] = []
    while let value = removeOptionValue(name) {
      values.append(value)
    }
    return values
  }
}

private extension Array where Element == AgentEvent {
  var coreAgentDebugDescription: String {
    guard !isEmpty else {
      return "Events: none"
    }

    return (["Events:"] + enumerated().map { index, event in
      var parts = ["\(index + 1). \(event.kind.rawValue)"]
      if let message = event.message, !message.isEmpty {
        parts.append(message.replacingOccurrences(of: "\n", with: " "))
      }
      if let errorType = event.errorType {
        parts.append("errorType=\(errorType)")
      }
      return parts.joined(separator: " - ")
    })
    .joined(separator: "\n")
  }
}
