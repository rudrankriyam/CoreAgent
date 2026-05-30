import Foundation
import KarmaKit
import KarmaKitFoundationModels
import KarmaKitTools

@main
struct KarmaCLI {
  static func main() async {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())

      guard !arguments.isEmpty else {
        printUsage()
        return
      }

      let listsTools = arguments.removeAll("--list-tools")
      let printsConfiguration = arguments.removeAll("--print-config")
      let enablesDemoTools = arguments.removeAll("--demo-tools")
      let enablesVerboseOutput = arguments.removeAll("--verbose")
      let enablesStreaming = arguments.removeAll("--stream")
      let enablesStructuredDemo = arguments.removeAll("--structured-demo")
      let enablesParallelTools = arguments.removeAll("--parallel-tools")
      let disablesRedaction = arguments.removeAll("--no-redaction")
      let tracePath = arguments.removeOptionValue("--trace")
      let receiptPath = arguments.removeOptionValue("--receipt")
      let maximumModelInputCharacters = arguments.removeOptionValue("--max-model-input-chars").flatMap(Int.init)
      let maximumToolOutputCharacters = arguments.removeOptionValue("--max-tool-output-chars").flatMap(Int.init)
      let maximumContextMessages = arguments.removeOptionValue("--max-context-messages").flatMap(Int.init)
      let modelTimeoutSeconds = arguments.removeOptionValue("--model-timeout-seconds").flatMap(Double.init)
      let allowedFileDirectories = arguments.removeOptionValues("--allow-file-dir")
      let prompt = arguments.joined(separator: " ")
      let tools = enablesDemoTools ? DemoTools.makeTools(allowedFileDirectories: allowedFileDirectories) : []
      let redactionPolicy: AgentRedactionPolicy = disablesRedaction ? .none : .standard
      let timeouts = AgentTimeouts(modelGeneration: modelTimeoutSeconds.map(Duration.seconds))

      if listsTools {
        try printToolManifests(for: tools)
        return
      }

      if printsConfiguration {
        try printAgentConfiguration(
          tools: tools,
          maximumModelInputCharacters: maximumModelInputCharacters,
          maximumToolOutputCharacters: maximumToolOutputCharacters,
          maximumContextMessages: maximumContextMessages,
          timeouts: timeouts,
          toolCallExecutionMode: enablesParallelTools ? .parallel : .sequential
        )
        return
      }

      if #available(macOS 26.0, *) {
        let provider = FoundationModelProvider(
          instructions: "Answer clearly and concisely. You are running inside KarmaKit."
        )
        if enablesStructuredDemo {
          let output = try await provider.generateStructuredContent(
            prompt: prompt,
            schemaName: "KarmaStructuredDemo",
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
          retryPolicy: RetryPolicy(maximumRetries: 1, delay: .milliseconds(200)),
          timeouts: timeouts,
          limits: AgentLimits(
            maximumModelInputCharacters: maximumModelInputCharacters,
            maximumToolOutputCharacters: maximumToolOutputCharacters,
            maximumContextMessages: maximumContextMessages
          ),
          toolCallExecutionMode: enablesParallelTools ? .parallel : .sequential,
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
            fputs("\n\(failedRun.events.karmaDebugDescription)\n", stderr)
          }
          throw error
        }

        if enablesVerboseOutput {
          fputs("\n\(run.events.karmaDebugDescription)\n", stderr)
        }
        try writeArtifacts(
          run: run,
          tracePath: tracePath,
          receiptPath: receiptPath,
          redactionPolicy: redactionPolicy
        )
      } else {
        fputs("Karma requires macOS 26 or newer for Foundation Models.\n", stderr)
        Foundation.exit(1)
      }
    } catch {
      fputs("\(error)\n", stderr)
      Foundation.exit(1)
    }
  }

  private static func printUsage() {
    print("Usage: karma <prompt>")
    print("       karma --demo-tools <prompt>")
    print("       karma --demo-tools --list-tools")
    print("       karma --demo-tools --print-config")
    print("       karma --verbose --demo-tools <prompt>")
    print("       karma --stream <prompt>")
    print("       karma --parallel-tools --demo-tools <prompt>")
    print("       karma --trace /tmp/karma-trace.json <prompt>")
    print("       karma --receipt /tmp/karma-receipt.json <prompt>")
    print("       karma --no-redaction --trace /tmp/karma-trace.json <prompt>")
    print("       karma --max-model-input-chars 12000 <prompt>")
    print("       karma --max-tool-output-chars 4000 --demo-tools <prompt>")
    print("       karma --max-context-messages 12 --demo-tools <prompt>")
    print("       karma --model-timeout-seconds 30 <prompt>")
    print("       karma --structured-demo <prompt>")
    print("       karma --demo-tools --allow-file-dir /tmp <prompt>")
    print("Example: karma Summarize tool calling in one sentence")
  }

  private static func printToolManifests(for tools: [any Tool]) throws {
    let manifests = try tools.map(ToolManifest.init(tool:))
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

  private static func printAgentConfiguration(
    tools: [any Tool],
    maximumModelInputCharacters: Int?,
    maximumToolOutputCharacters: Int?,
    maximumContextMessages: Int?,
    timeouts: AgentTimeouts,
    toolCallExecutionMode: ToolCallExecutionMode
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
        maximumContextMessages: maximumContextMessages
      ),
      toolCallExecutionMode: toolCallExecutionMode,
      toolManifests: try tools.map(ToolManifest.init(tool:)).sorted { $0.name < $1.name }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    print(String(decoding: data, as: UTF8.self))
  }
}

private enum DemoTools {
  static func makeTools(allowedFileDirectories: [String]) -> [any Tool] {
    var tools: [any Tool] = [
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
  var karmaDebugDescription: String {
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
