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
  private var upsertFailuresRemaining = 0

  func setFailsRemoval(_ value: Bool) {
    failsRemoval = value
  }

  func setUpsertFailures(_ count: Int) {
    upsertFailuresRemaining = count
  }

  func upsert(_ record: CoreAgentMemoryRecord) throws {
    if upsertFailuresRemaining > 0 {
      upsertFailuresRemaining -= 1
      throw TestMemoryError.intentional
    }
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

private actor ThrowingMemoryApprovalProvider: CoreAgentMemoryApprovalProvider {
  private(set) var calls = 0

  func decision(
    for candidate: CoreAgentMemoryCandidate
  ) throws -> CoreAgentMemoryApprovalDecision {
    calls += 1
    throw TestMemoryError.intentional
  }
}

private actor BlockingCountingConsolidator: CoreAgentMemoryConsolidator {
  private(set) var calls = 0
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func consolidate(episode: CoreAgentMemoryRecord) async -> [CoreAgentMemoryCandidateDraft] {
    calls += 1
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
    return []
  }

  func waitUntilStarted() async {
    guard calls == 0 else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finish() {
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
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

  @Test("A failed optional-index write stays canonical and repairs asynchronously")
  func indexRepair() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let index = TestMemoryIndex()
    await index.setUpsertFailures(1)
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      index: index
    )

    let record = try await coordinator.remember("repairable quasar record")
    #expect(record.status == .active)
    #expect(record.indexState == .pending)

    await coordinator.flush()

    #expect(await store.record(id: record.id, in: scope)?.indexState == .indexed)
    #expect(try await coordinator.search("quasar").map(\.id) == [record.id])
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

    try await coordinator.purge(original.id)
    #expect(await store.record(id: correction.id, in: scope)?.supersedes.isEmpty == true)
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

  @Test("Rich prompts require a query and dynamic profiles never receive injected context")
  func contextQueryBoundaries() async throws {
    let scope = try makeScope()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: InMemoryCoreAgentMemoryStore(),
      disclosurePolicy: .init(destination: .onDevice)
    )
    _ = try await coordinator.remember("A remembered comet preference.")
    let runID = UUID()

    let withoutQuery = try await coordinator.prepare(
      for: .init(
        runID: runID,
        prompt: Prompt("Rich prompt"),
        contextQuery: nil,
        metadata: [:],
        mode: .explicitModel
      )
    )
    let dynamicProfile = try await coordinator.prepare(
      for: .init(
        runID: runID,
        prompt: Prompt("Rich prompt"),
        contextQuery: "comet",
        metadata: [:],
        mode: .dynamicProfile
      )
    )

    #expect(withoutQuery.contextBlocks.isEmpty)
    #expect(dynamicProfile.contextBlocks.isEmpty)
    #expect(coordinator.searchTool.name == "coreagent_search_memory")
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

  @Test("Approval-provider failures remain durable and exhaust the retry policy")
  func approvalFailureRetryExhaustion() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let episode = try makeRecord(
      scope: scope,
      content: "USER:\nI prefer gyokuro tea.",
      kind: .episode
    )
    try await store.saveEpisode(
      episode,
      enqueueing: .init(scope: scope, episodeID: episode.id)
    )
    let approvalProvider = ThrowingMemoryApprovalProvider()
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: TestConsolidator(
        drafts: [try .init(kind: .preference, content: "The user prefers gyokuro tea.")]
      ),
      approvalProvider: approvalProvider
    )

    await coordinator.flush()

    let failure = try #require(try await coordinator.consolidationFailures().first)
    #expect(failure.attemptCount == 3)
    #expect(await approvalProvider.calls == 3)
    #expect(try await coordinator.pendingCandidates().count == 1)
  }

  @Test("A shared store atomically claims each consolidation job once")
  func atomicConsolidationClaim() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scope = try makeScope()
    let stores: [any CoreAgentMemoryStore] = [
      InMemoryCoreAgentMemoryStore(),
      try SQLiteCoreAgentMemoryStore(
        databaseURL: directory.appending(path: "claims.sqlite"),
        configuration: .init(fileProtection: .none, excludesFromBackup: false)
      ),
    ]

    for store in stores {
      let episode = try makeRecord(scope: scope, content: "USER:\nRemember this.", kind: .episode)
      let job = CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
      try await store.saveEpisode(episode, enqueueing: job)

      async let firstClaim = store.claimNextConsolidationJob(in: scope)
      async let secondClaim = store.claimNextConsolidationJob(in: scope)
      let (first, second) = try await (firstClaim, secondClaim)
      let claims = [first, second].compactMap { $0 }

      #expect(claims.count == 1)
      var claimed = try #require(claims.first)
      #expect(claimed.status == .processing)
      #expect(claimed.attemptCount == 1)
      await store.releaseConsolidationJobClaim(id: claimed.id, in: scope)
      claimed = try #require(try await store.claimNextConsolidationJob(in: scope))
      #expect(claimed.status == .processing)
      #expect(claimed.attemptCount == 2)
      claimed.status = .completed
      try await store.save(claimed)
      #expect(try await store.claimNextConsolidationJob(in: scope) == nil)
    }
  }

  @Test("Coordinators sharing a store do not consolidate the same episode twice")
  func sharedStoreSingleConsolidation() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let episode = try makeRecord(scope: scope, content: "USER:\nOne episode.", kind: .episode)
    let job = CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
    try await store.saveEpisode(episode, enqueueing: job)
    let consolidator = BlockingCountingConsolidator()
    let first = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: consolidator
    )
    let second = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: consolidator
    )

    await consolidator.waitUntilStarted()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await consolidator.calls == 1)
    await consolidator.finish()
    await first.flush()
    await second.flush()

    #expect(await consolidator.calls == 1)
    #expect(await store.consolidationJob(id: job.id, in: scope)?.status == .completed)
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

  @Test("Forgotten episodes do not consolidate pending jobs")
  func forgottenEpisodesSkipConsolidation() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let episode = try makeRecord(scope: scope, content: "USER:\nI prefer matcha.", kind: .episode)
    try await store.saveEpisode(
      episode,
      enqueueing: .init(scope: scope, episodeID: episode.id)
    )
    let consolidator = TestConsolidator(
      drafts: [try .init(kind: .preference, content: "The user prefers matcha.")]
    )
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: consolidator
    )

    try await coordinator.forget(episode.id, reason: "user_request")
    await coordinator.flush()

    #expect(await consolidator.calls == 0)
    #expect(try await coordinator.pendingCandidates().isEmpty)
  }

  @Test("Approving a candidate from a forgotten episode fails")
  func forgottenEpisodesCannotApproveCandidates() async throws {
    let scope = try makeScope()
    let store = InMemoryCoreAgentMemoryStore()
    let episode = try makeRecord(scope: scope, content: "USER:\nI prefer sencha.", kind: .episode)
    try await store.saveEpisode(
      episode,
      enqueueing: .init(scope: scope, episodeID: episode.id)
    )
    let coordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: store,
      disclosurePolicy: .init(destination: .onDevice),
      consolidator: TestConsolidator(
        drafts: [try .init(kind: .preference, content: "The user prefers sencha.")]
      )
    )

    await coordinator.flush()
    let candidate = try #require(try await coordinator.pendingCandidates().first)

    try await coordinator.forget(episode.id, reason: "user_request")

    await #expect(throws: CoreAgentMemoryError.self) {
      _ = try await coordinator.approve(candidate.id)
    }
  }

  @Test("Tombstoning an episode cancels every pending derivative")
  func tombstoneCancelsPendingDerivatives() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let scope = try makeScope()
    let stores: [any CoreAgentMemoryStore] = [
      InMemoryCoreAgentMemoryStore(),
      try SQLiteCoreAgentMemoryStore(
        databaseURL: directory.appending(path: "memory.sqlite"),
        configuration: .init(fileProtection: .none, excludesFromBackup: false)
      ),
    ]

    for store in stores {
      let episode = try makeRecord(
        scope: scope,
        content: "USER:\nI prefer sencha tea.",
        kind: .episode
      )
      let job = CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
      let draft = try CoreAgentMemoryCandidateDraft(
        kind: .preference,
        content: "The user prefers sencha tea.",
        authority: .priorUserStatement
      )
      let candidate = CoreAgentMemoryCandidate(
        scope: scope,
        sourceRecordID: episode.id,
        draft: draft
      )
      try await store.saveEpisode(episode, enqueueing: job)
      try await store.save(candidate)

      _ = try await store.tombstone(id: episode.id, in: scope, reason: "forgotten")

      #expect(try await store.consolidationJob(id: job.id, in: scope)?.status == .cancelled)
      let rejected = try #require(try await store.candidate(id: candidate.id, in: scope))
      #expect(rejected.status == .rejected)
      #expect(rejected.decisionReason == "source_tombstoned")
      await #expect(throws: CoreAgentMemoryError.self) {
        try await store.save(
          CoreAgentMemoryCandidate(
            scope: scope,
            sourceRecordID: episode.id,
            draft: draft
          )
        )
      }

      let consolidator = TestConsolidator(drafts: [draft])
      let coordinator = CoreAgentMemoryCoordinator(
        scope: scope,
        store: store,
        disclosurePolicy: .init(destination: .onDevice),
        consolidator: consolidator
      )
      await coordinator.flush()
      #expect(await consolidator.calls == 0)
      await #expect(throws: CoreAgentMemoryError.self) {
        _ = try await coordinator.approve(candidate.id)
      }
    }

    var inactiveEpisode = try makeRecord(
      scope: scope,
      content: "USER:\nI prefer matcha.",
      kind: .episode
    )
    inactiveEpisode.status = .tombstoned
    let pendingCandidate = CoreAgentMemoryCandidate(
      scope: scope,
      sourceRecordID: inactiveEpisode.id,
      draft: try .init(
        kind: .preference,
        content: "The user prefers matcha.",
        authority: .priorUserStatement
      )
    )
    let recoveryStore = InMemoryCoreAgentMemoryStore(
      records: [inactiveEpisode],
      candidates: [pendingCandidate]
    )
    let recoveryCoordinator = CoreAgentMemoryCoordinator(
      scope: scope,
      store: recoveryStore,
      disclosurePolicy: .init(destination: .onDevice)
    )
    await #expect(throws: CoreAgentMemoryError.self) {
      _ = try await recoveryCoordinator.approve(pendingCandidate.id)
    }
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
