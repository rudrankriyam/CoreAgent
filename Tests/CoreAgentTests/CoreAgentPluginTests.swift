import CoreAgent
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

private enum TestPluginError: Error {
  case preparation
  case completion
}

private actor TestPluginProbe {
  private(set) var preparationCount = 0
  private(set) var completionCount = 0
  private(set) var failureCount = 0
  private(set) var requests: [CoreAgentPluginRequest] = []
  private(set) var completions: [CoreAgentPluginCompletion] = []

  func recordPreparation(_ request: CoreAgentPluginRequest) {
    preparationCount += 1
    requests.append(request)
  }

  func recordCompletion(_ completion: CoreAgentPluginCompletion) {
    completionCount += 1
    completions.append(completion)
  }

  func recordFailure() {
    failureCount += 1
  }
}

private struct TestSessionPlugin: CoreAgentSessionPlugin {
  let identifier: String
  let probe: TestPluginProbe
  let contextBlocks: [CoreAgentContextBlock]
  let tools: [any Tool]
  let failurePolicies: CoreAgentPluginFailurePolicies
  let failsPreparation: Bool
  let failsCompletion: Bool

  init(
    identifier: String = "test.plugin",
    probe: TestPluginProbe,
    contextBlocks: [CoreAgentContextBlock] = [],
    tools: [any Tool] = [],
    failurePolicies: CoreAgentPluginFailurePolicies = .default,
    failsPreparation: Bool = false,
    failsCompletion: Bool = false
  ) {
    self.identifier = identifier
    self.probe = probe
    self.contextBlocks = contextBlocks
    self.tools = tools
    self.failurePolicies = failurePolicies
    self.failsPreparation = failsPreparation
    self.failsCompletion = failsCompletion
  }

  func prepare(for request: CoreAgentPluginRequest) async throws -> CoreAgentPluginPreparation {
    await probe.recordPreparation(request)
    if failsPreparation {
      throw TestPluginError.preparation
    }
    return CoreAgentPluginPreparation(contextBlocks: contextBlocks)
  }

  func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    await probe.recordCompletion(completion)
    if failsCompletion {
      throw TestPluginError.completion
    }
    return [
      CoreAgentPluginEvent(name: "captured", message: "Test plugin captured the run.")
    ]
  }

  func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    await probe.recordFailure()
    return []
  }
}

@Generable
private struct PluginToolArguments: Sendable {
  let value: String
}

private struct PluginTool: Tool {
  let name: String
  let description = "Returns the provided value."

  @concurrent
  func call(arguments: PluginToolArguments) async throws -> String {
    arguments.value
  }
}

private func promptText(in entries: some Sequence<Transcript.Entry>) -> [String] {
  entries.flatMap { entry -> [String] in
    guard case .prompt(let prompt) = entry else { return [] }
    return prompt.segments.compactMap { segment in
      guard case .text(let text) = segment else { return nil }
      return text.content
    }
  }
}

@Suite("CoreAgent session plugins")
struct CoreAgentPluginTests {
  @Test("Prepares once across retries and removes injected context from durable history")
  func contextLifecycleAcrossRetry() async throws {
    let probe = TestPluginProbe()
    let plugin = TestSessionPlugin(
      probe: probe,
      contextBlocks: [
        CoreAgentContextBlock(
          id: "memory-record-1",
          content: "Untrusted recalled evidence: the preferred color is blue."
        )
      ]
    )
    let retry = try CoreAgentRetryPolicy(maximumAttempts: 2) { _ in true }
    let model = RecordedLanguageModel(steps: [
      .failure("temporary"),
      .response(text: "blue"),
    ])
    let checkpointStore = InMemoryCheckpointStore()
    let session = try CoreAgentSession(
      model: model,
      configuration: .init(retryPolicy: retry),
      checkpointStore: checkpointStore,
      plugins: [plugin]
    )

    let response = try await session.respond(to: "What is my preferred color?")

    #expect(response.content == "blue")
    #expect(await probe.preparationCount == 1)
    #expect(await probe.completionCount == 1)
    #expect(await probe.failureCount == 0)
    #expect(model.recorder.capturedTranscripts().count == 2)
    #expect(
      model.recorder.capturedTranscripts().allSatisfy {
        promptText(in: $0).contains("Untrusted recalled evidence: the preferred color is blue.")
      }
    )

    let activeText = promptText(in: try await session.transcript())
    #expect(!activeText.contains("Untrusted recalled evidence: the preferred color is blue."))
    #expect(activeText.contains("What is my preferred color?"))

    let checkpoint = try #require(await checkpointStore.loadCheckpoint(for: "default"))
    let checkpointText = promptText(in: checkpoint.transcript)
    #expect(!checkpointText.contains("Untrusted recalled evidence: the preferred color is blue."))
    #expect(checkpointText.contains("What is my preferred color?"))

    let completion = try #require(await probe.completions.first)
    #expect(
      !promptText(in: completion.transcriptEntries).contains(
        "Untrusted recalled evidence: the preferred color is blue."
      )
    )
    #expect(
      response.run.events.contains {
        $0.kind == .pluginEvent && $0.attributes["context_block_id"] == "memory-record-1"
      }
    )
  }

  @Test("Applies the same plugin lifecycle to streaming responses")
  func streamingLifecycle() async throws {
    let probe = TestPluginProbe()
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.responseFragments(["hel", "lo"])]),
      plugins: [
        TestSessionPlugin(
          probe: probe,
          contextBlocks: [CoreAgentContextBlock(id: "context", content: "Context")]
        )
      ]
    )

    let response = try await session.respondStreaming(
      to: Prompt("Greet me"),
      contextQuery: "greeting"
    ) { _ in }

    #expect(response.content == "hello")
    #expect(await probe.preparationCount == 1)
    #expect(await probe.completionCount == 1)
    #expect(!promptText(in: try await session.transcript()).contains("Context"))
  }

  @Test("Plugin preparation failures continue or fail according to policy")
  func preparationFailurePolicy() async throws {
    let continuingProbe = TestPluginProbe()
    let continuing = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "continued")]),
      plugins: [TestSessionPlugin(probe: continuingProbe, failsPreparation: true)]
    )

    #expect(try await continuing.respond(to: "Continue").content == "continued")
    #expect(await continuingProbe.completionCount == 1)

    let failingProbe = TestPluginProbe()
    let failing = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "unused")]),
      plugins: [
        TestSessionPlugin(
          probe: failingProbe,
          failurePolicies: .init(preparation: .failRun),
          failsPreparation: true
        )
      ]
    )

    await #expect(throws: TestPluginError.self) {
      _ = try await failing.respond(to: "Fail")
    }
    #expect(await failingProbe.failureCount == 1)
  }

  @Test("Plugin tools participate in duplicate-name validation")
  func duplicatePluginToolName() throws {
    let probe = TestPluginProbe()
    #expect(throws: CoreAgentError.self) {
      _ = try CoreAgentSession(
        model: RecordedLanguageModel(steps: []),
        tools: [PluginTool(name: "duplicate")],
        plugins: [
          TestSessionPlugin(
            probe: probe,
            tools: [PluginTool(name: "duplicate")]
          )
        ]
      )
    }
  }

  @Test("Rejects duplicate plugin identifiers")
  func duplicatePluginIdentifiers() throws {
    let first = TestSessionPlugin(probe: TestPluginProbe())
    let second = TestSessionPlugin(probe: TestPluginProbe())

    #expect(throws: CoreAgentError.self) {
      _ = try CoreAgentSession(
        model: RecordedLanguageModel(steps: []),
        plugins: [first, second]
      )
    }
  }
}
