import Foundation
import KarmaKit
import KarmaKitFoundationModels

@main
struct KarmaCLI {
  static func main() async {
    do {
      var arguments = Array(CommandLine.arguments.dropFirst())

      guard !arguments.isEmpty else {
        printUsage()
        return
      }

      let enablesDemoTools = arguments.removeAll("--demo-tools")
      let enablesVerboseOutput = arguments.removeAll("--verbose")
      let enablesStreaming = arguments.removeAll("--stream")
      let prompt = arguments.joined(separator: " ")

      if #available(macOS 26.0, *) {
        let provider = FoundationModelProvider(
          instructions: "Answer clearly and concisely. You are running inside KarmaKit."
        )
        let agent = try ToolCallingAgent(
          tools: enablesDemoTools ? DemoTools.all : [],
          model: provider,
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
    print("       karma --verbose --demo-tools <prompt>")
    print("       karma --stream <prompt>")
    print("Example: karma Summarize tool calling in one sentence")
  }
}

private enum DemoTools {
  static var all: [any Tool] {
    [
      ClosureTool(
        name: "current_time",
        description: "Returns the current date and time in ISO 8601 format.",
        inputs: [:]
      ) { _ in
        ISO8601DateFormatter().string(from: Date())
      },
      ClosureTool(
        name: "multiply",
        description: "Multiplies two numbers and returns the result.",
        inputs: [
          "left": ToolInput(type: .number, description: "The first number."),
          "right": ToolInput(type: .number, description: "The second number.")
        ]
      ) { arguments in
        let left = Double(arguments["left", default: "0"]) ?? 0
        let right = Double(arguments["right", default: "0"]) ?? 0
        return String(left * right)
      }
    ]
  }
}

private extension Array where Element == String {
  mutating func removeAll(_ value: String) -> Bool {
    let originalCount = count
    self = filter { $0 != value }
    return count != originalCount
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
