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
      let enablesDemoTools = arguments.removeAll("--demo-tools")
      let enablesVerboseOutput = arguments.removeAll("--verbose")
      let enablesStreaming = arguments.removeAll("--stream")
      let enablesStructuredDemo = arguments.removeAll("--structured-demo")
      let disablesRedaction = arguments.removeAll("--no-redaction")
      let tracePath = arguments.removeOptionValue("--trace")
      let receiptPath = arguments.removeOptionValue("--receipt")
      let maximumToolOutputCharacters = arguments.removeOptionValue("--max-tool-output-chars").flatMap(Int.init)
      let allowedFileDirectories = arguments.removeOptionValues("--allow-file-dir")
      let prompt = arguments.joined(separator: " ")
      let tools = enablesDemoTools ? DemoTools.makeTools(allowedFileDirectories: allowedFileDirectories) : []
      let redactionPolicy: AgentRedactionPolicy = disablesRedaction ? .none : .standard

      if listsTools {
        try printToolManifests(for: tools)
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
          limits: AgentLimits(maximumToolOutputCharacters: maximumToolOutputCharacters),
          validatesToolNames: true
        )
        let run: AgentRun
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

        if enablesVerboseOutput {
          fputs("\n\(run.events.karmaDebugDescription)\n", stderr)
        }
        if let tracePath {
          try AgentTraceExporter(redactionPolicy: redactionPolicy).write(run, to: URL(fileURLWithPath: tracePath))
          fputs("Trace written to \(tracePath)\n", stderr)
        }
        if let receiptPath {
          try AgentReceiptExporter(redactionPolicy: redactionPolicy).write(run, to: URL(fileURLWithPath: receiptPath))
          fputs("Receipt written to \(receiptPath)\n", stderr)
        }
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
    print("       karma --verbose --demo-tools <prompt>")
    print("       karma --stream <prompt>")
    print("       karma --trace /tmp/karma-trace.json <prompt>")
    print("       karma --receipt /tmp/karma-receipt.json <prompt>")
    print("       karma --no-redaction --trace /tmp/karma-trace.json <prompt>")
    print("       karma --max-tool-output-chars 4000 --demo-tools <prompt>")
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
      return parts.joined(separator: " - ")
    })
    .joined(separator: "\n")
  }
}
