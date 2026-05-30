import Testing
@testable import KarmaKit

@Test func toolCallingAgentRunsToolBeforeFinalAnswer() async throws {
  let weatherTool = ClosureTool(
    name: "get_weather",
    description: "Gets the weather for a location.",
    inputs: [
      "location": ToolInput(type: .string, description: "The city to inspect.")
    ]
  ) { arguments in
    "It is sunny in \(arguments["location", default: "somewhere"])."
  }

  let model = ScriptedModel(outputs: [
    .toolCalls([
      ToolCall(id: "call_1", name: "get_weather", arguments: ["location": "Paris"])
    ]),
    .finalAnswer("It is sunny in Paris.")
  ])

  let agent = ToolCallingAgent(tools: [weatherTool], model: model)
  let run = try await agent.run("What is the weather in Paris?")

  #expect(run.finalAnswer == "It is sunny in Paris.")
  #expect(run.steps.count == 2)
  #expect(run.steps.first?.toolResults.first?.output == "It is sunny in Paris.")
  #expect(run.steps.last?.isFinalAnswer == true)
}

@Test func closureToolValidatesRequiredArguments() async throws {
  let tool = ClosureTool(
    name: "echo",
    description: "Echoes text.",
    inputs: [
      "text": ToolInput(type: .string, description: "Text to echo.")
    ]
  ) { arguments in
    arguments["text", default: ""]
  }

  await #expect(throws: KarmaError.invalidToolArguments(tool: "echo", expected: ["text"])) {
    _ = try await tool.call(arguments: [:])
  }
}
