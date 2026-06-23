import CoreAgent
import CoreAgentMemory
import Foundation
import FoundationModels
import Testing

private enum TestMemoryError: Error {
  case intentional
}

private actor TestMemoryIndex: CoreAgentMemoryIndex {
  private var records: [UUID: CoreAgentMemoryRecord] = [:]
  private var failsRemoval = false

  func setFailsRemoval(_ value: Bool) {
    failsRemoval = value
  }

  func upsert(_ record: CoreAgentMemoryRecord) {
    records[record.id] = record
  }

  func search(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) -> [CoreAgentMemorySearchCandidate] {
    records.values
      .filter { $0.scope == scope && $0.content.localizedCaseInsensitiveContains(query) }
      .prefix(limit)
      .map { CoreAgentMemorySearchCandidate(id: $0.id, score: 1) }
  }

  func remove(id: UUID, in scope: CoreAgentMemoryScope) throws {
    if failsRemoval { throw TestMemoryError.intentional }
    guard records[id]?.scope == scope else { return }
    records.removeValue(forKey: id)
  }

  func removeAll(in scope: CoreAgentMemoryScope) throws {
    if failsRemoval { throw TestMemoryError.intentional }
    records = records.filter { $0.value.scope != scope }
  }
}

private actor TestConsolidator: CoreAgentMemoryConsolidator {
  private var failuresRemaining: Int
  private let drafts: [CoreAgentMemoryCandidateDraft]
  private(set) var calls = 0

  init(failuresRemaining: Int = 0, drafts: [CoreAgentMemoryCandidateDraft]) {
    self.failuresRemaining = failuresRemaining
    self.drafts = drafts
  }

  func consolidate(episode: CoreAgentMemoryRecord) throws -> [CoreAgentMemoryCandidateDraft] {
    calls += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw TestMemoryError.intentional
    }
    return drafts
  }
}

private struct ApproveAllMemoryCandidates: CoreAgentMemoryApprovalProvider {
  func decision(for candidate: CoreAgentMemoryCandidate) -> CoreAgentMemoryApprovalDecision {
    .approve
  }
}

private func makeScope(
  application: String = "com.example.app",
  user: String = "user-1",
  agent: String = "assistant"
) throws -> CoreAgentMemoryScope {
  try CoreAgentMemoryScope(applicationID: application, userID: user, agentID: agent)
}

private func makeRecord(
  id: UUID = UUID(),
  scope: CoreAgentMemoryScope,
  content: String,
  kind: CoreAgentMemoryKind = .fact,
  status: CoreAgentMemoryStatus = .active,
  authority: CoreAgentMemoryAuthority = .priorUserStatement,
  sensitivity: CoreAgentMemorySensitivity = .personal,
  observedAt: Date = Date(),
  validFrom: Date? = nil,
  validUntil: Date? = nil
) throws -> CoreAgentMemoryRecord {
  try CoreAgentMemoryRecord(
    id: id,
    scope: scope,
    kind: kind,
    content: content,
    source: .init(kind: .conversation),
    observedAt: observedAt,
    validFrom: validFrom,
    validUntil: validUntil,
    authority: authority,
    sensitivity: sensitivity,
    status: status,
    createdAt: observedAt
  )
}

private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appending(path: "CoreAgentMemoryTests")
    .appending(path: name)
  try? FileManager.default.removeItem(at: url)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Suite("CoreAgent production memory")
struct CoreAgentMemoryTests {
  @Test("Requires an explicit application, user, and agent scope")
  func scopeValidation() {
    #expect(throws: CoreAgentMemoryError.self) {
      _ = try CoreAgentMemoryScope(applicationID: "", userID: "user", agentID: "agent")
    }
    #expect(throws: CoreAgentMemoryError.self) {
      _ = try CoreAgentMemoryScope(applicationID: "app", userID: "", agentID: "agent")
    }
    #expect(throws: CoreAgentMemoryError.self) {
      _ = try CoreAgentMemoryScope(applicationID: "app", userID: "user", agentID: "")
    }
  }

  @Test("SQLite FTS persists canonical records and isolates every scope component")
  func sqlitePersistenceAndScopeIsolation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "memory.sqlite")
    let configuration = SQLiteCoreAgentMemoryStoreConfiguration(
      fileProtection: .none,
      excludesFromBackup: false
    )
    let firstScope = try makeScope(user: "first")
    let secondScope = try makeScope(user: "second")
    let firstRecord = try makeRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
      scope: firstScope,
      content: "The launch color is ultraviolet."
    )
    let secondRecord = try makeRecord(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
      scope: secondScope,
      content: "The launch color is ultraviolet."
    )
    let store = try SQLiteCoreAgentMemoryStore(
      databaseURL: databaseURL,
      configuration: configuration
    )
    try await store.save(firstRecord)
    try await store.save(secondRecord)

    let firstHits = try await store.lexicalSearch(
      query: "ultraviolet",
      in: firstScope,
      limit: 10
    )
    #expect(firstHits.map(\.id) == [firstRecord.id])
    #expect(try await store.record(id: secondRecord.id, in: firstScope) == nil)

    let reopened = try SQLiteCoreAgentMemoryStore(
      databaseURL: databaseURL,
      configuration: configuration
    )
    #expect(try await reopened.record(id: firstRecord.id, in: firstScope) == firstRecord)

    _ = try await reopened.tombstone(id: firstRecord.id, in: firstScope, reason: "forgotten")
    #expect(
      try await reopened.lexicalSearch(query: "ultraviolet", in: firstScope, limit: 10).isEmpty
    )
  }

  @Test("Canonical filtering blocks stale-index, tombstoned, expired, and restricted records")
  func canonicalFiltering() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let index = TestMemoryIndex()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .remote),
      index: index
    )
    let visible = try await coordinator.remember("visible nebula record", sensitivity: .personal)
    _ = try await coordinator.remember("restricted nebula record", sensitivity: .restricted)
    _ = try await coordinator.remember(
      "expired nebula record",
      validUntil: Date(timeIntervalSinceNow: -60)
    )
    await index.setFailsRemoval(true)
    try await coordinator.forget(visible.id)

    #expect(try await coordinator.search("nebula").isEmpty)
    #expect(await store.tombstone(id: visible.id, in: scope) != nil)
  }

  @Test("Corrections append provenance and supersede rather than overwrite")
  func correctionAuthority() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice)
    )
    let original = try await coordinator.remember(
      "The preferred color is blue.",
      authority: .priorUserStatement
    )
    let correction = try await coordinator.correct(
      recordIDs: [original.id],
      with: "The preferred color is green."
    )

    let storedOriginal = try #require(await store.record(id: original.id, in: scope))
    #expect(storedOriginal.status == .superseded)
    #expect(storedOriginal.supersededBy == correction.id)
    #expect(correction.supersedes == [original.id])
    #expect(correction.authority == .explicitUserCorrection)
    #expect(try await coordinator.search("green").map(\.id) == [correction.id])
    #expect(try await coordinator.search("blue").isEmpty)
  }

  @Test("Context packing is bounded, delimited, and records source identifiers")
  func boundedContext() async throws {
    let scope = try makeScope()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: InMemoryCoreAgentMemoryStore(),
      disclosurePolicy: .init(destination: .onDevice),
      retrievalConfiguration: .init(
        maximumRecords: 2,
        maximumCharacters: 500,
        overfetchMultiplier: 2
      )
    )
    _ = try await coordinator.remember(String(repeating: "starlight ", count: 200))

    let preparation = try await coordinator.prepare(
      for: CoreAgentPluginRequest(
        runID: UUID(),
        prompt: Prompt("Recall"),
        contextQuery: "starlight",
        metadata: [:],
        mode: .explicitModel
      )
    )
    let block = try #require(preparation.contextBlocks.first)
    #expect(block.content.count <= 500)
    #expect(block.content.hasPrefix("COREAGENT_UNTRUSTED_MEMORY_EVIDENCE_V1"))
    #expect(block.content.contains("contentTruncated"))
    #expect(block.content.hasSuffix("END_COREAGENT_UNTRUSTED_MEMORY_EVIDENCE"))
    #expect(preparation.events.first?.attributes["record_id"] != nil)
  }

  @Test("Durable consolidation resumes, retries three times, and exposes terminal failure")
  func consolidationRetryExhaustion() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let episode = try makeRecord(scope: scope, content: "USER:\nI prefer tea.", kind: .episode)
    let job = CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
    try await store.saveEpisode(episode, enqueueing: job)
    let consolidator = TestConsolidator(
      failuresRemaining: 3,
      drafts: [try .init(kind: .preference, content: "The user prefers tea.")]
    )
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: consolidator
    )

    await coordinator.flush()

    let failure = try #require(try await coordinator.consolidationFailures().first)
    #expect(failure.attemptCount == 3)
    #expect(await consolidator.calls == 3)
  }

  @Test("Consolidated semantics stay pending until policy approval")
  func consolidationApproval() async throws {
    let scope = try makeScope()
    let pendingStore = InMemoryCoreAgentMemoryStore()
    let pendingEpisode = try makeRecord(
      scope: scope,
      content: "USER:\nI prefer jasmine tea.",
      kind: .episode
    )
    try await pendingStore.saveEpisode(
      pendingEpisode,
      enqueueing: .init(scope: scope, episodeID: pendingEpisode.id)
    )
    let draft = try CoreAgentMemoryCandidateDraft(
      kind: .preference,
      content: "The user prefers jasmine tea.",
      authority: .priorUserStatement
    )
    let pendingCoordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: pendingStore,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: TestConsolidator(drafts: [draft])
    )
    await pendingCoordinator.flush()

    #expect(try await pendingCoordinator.pendingCandidates().count == 1)
    #expect(try await pendingCoordinator.search("jasmine").map(\.record.kind) == [.episode])

    let approvedStore = InMemoryCoreAgentMemoryStore()
    let approvedEpisode = try makeRecord(
      scope: scope,
      content: "USER:\nI prefer oolong tea.",
      kind: .episode
    )
    try await approvedStore.saveEpisode(
      approvedEpisode,
      enqueueing: .init(scope: scope, episodeID: approvedEpisode.id)
    )
    let approvedCoordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: approvedStore,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: TestConsolidator(
        drafts: [try .init(kind: .preference, content: "The user prefers oolong tea.")]
      ),
      approvalProvider: ApproveAllMemoryCandidates()
    )
    await approvedCoordinator.flush()

    #expect(try await approvedCoordinator.pendingCandidates().isEmpty)
    #expect(
      try await approvedCoordinator.search("oolong").contains {
        $0.record.kind == .preference
      }
    )
  }

  @Test("Markdown export is deterministic and purge removes registered artifacts")
  func deterministicExportAndPurge() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice)
    )
    let record = try await coordinator.remember("A readable durable record.")
    let first = root.appending(path: "first")
    let second = root.appending(path: "second")
    let date = Date(timeIntervalSince1970: 1_000)
    let configuration = CoreAgentMemoryMarkdownExportConfiguration(
      fileProtection: .none,
      excludesFromBackup: false
    )

    _ = try await coordinator.exportMarkdown(
      to: first,
      exportedAt: date,
      configuration: configuration
    )
    _ = try await coordinator.exportMarkdown(
      to: second,
      exportedAt: date,
      configuration: configuration
    )
    let filename = record.id.uuidString.lowercased() + ".md"
    #expect(
      try Data(contentsOf: first.appending(path: filename))
        == Data(contentsOf: second.appending(path: filename))
    )
    #expect(
      try Data(contentsOf: first.appending(path: "manifest.json"))
        == Data(contentsOf: second.appending(path: "manifest.json"))
    )

    try await coordinator.purge(record.id)
    #expect(!FileManager.default.fileExists(atPath: first.appending(path: filename).path))
    #expect(!FileManager.default.fileExists(atPath: second.appending(path: filename).path))
  }

}
