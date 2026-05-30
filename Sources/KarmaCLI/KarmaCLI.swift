import Foundation
import KarmaKit
import KarmaKitFoundationModels

@main
struct KarmaCLI {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())

      guard !arguments.isEmpty else {
        printUsage()
        return
      }

      let prompt = arguments.joined(separator: " ")

      if #available(macOS 26.0, *) {
        let provider = FoundationModelProvider(
          instructions: "Answer clearly and concisely. You are running inside KarmaKit."
        )
        let agent = ToolCallingAgent(tools: [], model: provider)
        let run = try await agent.run(prompt)
        print(run.finalAnswer)
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
    print("Example: karma Summarize tool calling in one sentence")
  }
}
