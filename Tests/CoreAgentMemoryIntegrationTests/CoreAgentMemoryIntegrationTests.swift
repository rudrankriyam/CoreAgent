import CoreAgent
import CoreAgentMemory
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgent memory native-session integration")
struct CoreAgentMemoryIntegrationTests {
  @Test("Search-tool evidence is excluded from captured episodes")
  func noMemoryOfMemoryRecursion() async throws {
    let scope = try CoreAgentMemoryScope(
      applicationID: "com.example.integration",
      userID: "user",
      agentID: "assistant"
    )
    let store = InMemoryCoreAgentMemoryStore()
    let memory = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice)
    )
    _ = try await memory.remember("unique-memory-payload", sensitivity: .general)
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        name: "coreagent_search_memory",
        argumentsJSON: #"{"query":"unique-memory-payload","maximumResults":1}"#
      ),
      .response(text: "done"),
    ])
    let session = try CoreAgentSession(model: model, plugins: [memory])

    _ = try await session.respond(to: Prompt("Use the memory search tool."))

    let episodes = await store.records(in: scope).filter { $0.kind == .episode }
    let episode = try #require(episodes.first)
    #expect(!episode.content.contains("unique-memory-payload"))
    #expect(episode.content.contains("Use the memory search tool."))
    #expect(episode.content.contains("done"))
  }
}
