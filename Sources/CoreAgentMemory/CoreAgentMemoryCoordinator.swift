import CoreAgent
import Foundation
import FoundationModels

public actor CoreAgentMemoryCoordinator: CoreAgentSessionPlugin {
  public nonisolated let identifier = "coreagent.memory"
  public nonisolated let scope: CoreAgentMemoryScope
  public nonisolated let searchTool: CoreAgentMemorySearchTool
  public nonisolated let failurePolicies: CoreAgentPluginFailurePolicies

  public nonisolated var tools: [any Tool] { [searchTool] }

  private let store: any CoreAgentMemoryStore
  private let runtime: CoreAgentMemoryRuntime
  private let consolidator: (any CoreAgentMemoryConsolidator)?
  private let consolidationWorker: CoreAgentMemoryConsolidationWorker?

  public init(
    scope: CoreAgentMemoryScope,
    store: any CoreAgentMemoryStore,
    disclosurePolicy: CoreAgentMemoryDisclosurePolicy,
    index: (any CoreAgentMemoryIndex)? = nil,
    consolidator: (any CoreAgentMemoryConsolidator)? = nil,
    approvalProvider: any CoreAgentMemoryApprovalProvider =
      DeferCoreAgentMemoryApprovalProvider(),
    retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration = .default,
    failurePolicies: CoreAgentPluginFailurePolicies = .default,
    observers: [any CoreAgentMemoryObserver] = []
  ) {
    let runtime = CoreAgentMemoryRuntime(
      scope: scope,
      store: store,
      index: index,
      disclosurePolicy: disclosurePolicy,
      retrievalConfiguration: retrievalConfiguration,
      observers: observers
    )
    self.scope = scope
    self.store = store
    self.runtime = runtime
    self.searchTool = CoreAgentMemorySearchTool(runtime: runtime)
    self.consolidator = consolidator
    self.failurePolicies = failurePolicies
    if let consolidator {
      let worker = CoreAgentMemoryConsolidationWorker(
        scope: scope,
        store: store,
        consolidator: consolidator,
        approvalProvider: approvalProvider,
        runtime: runtime
      )
      self.consolidationWorker = worker
      Task { await worker.resume() }
    } else {
      self.consolidationWorker = nil
    }
  }

  public func prepare(for request: CoreAgentPluginRequest) async throws
    -> CoreAgentPluginPreparation
  {
    guard request.mode == .explicitModel,
      let query = request.contextQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
      !query.isEmpty
    else {
      return .empty
    }

    let results = try await runtime.search(query: query)
    guard !results.isEmpty else { return .empty }
    let context = await runtime.format(results)
    await runtime.emit(
      .init(
        kind: .contextInjected,
        scope: scope,
        attributes: ["record_count": String(results.count)]
      )
    )
    return CoreAgentPluginPreparation(
      contextBlocks: [
        CoreAgentContextBlock(
          id: CoreAgentMemoryContextFormatter.blockID(for: results),
          content: context,
          attributes: ["record_count": String(results.count)]
        )
      ],
      events: results.map {
        CoreAgentPluginEvent(
          name: "memory_retrieved",
          message: "CoreAgent memory record was selected for context.",
          attributes: ["record_id": $0.id.uuidString.lowercased()]
        )
      }
    )
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    guard let capture = Self.captureEpisode(from: completion) else { return [] }
    var episode = try CoreAgentMemoryRecord(
      scope: scope,
      kind: .episode,
      content: capture.content,
      source: CoreAgentMemorySource(
        kind: .conversation,
        runID: completion.runID,
        transcriptEntryIDs: capture.transcriptEntryIDs,
        assetReferences: capture.assetReferences,
        metadata: ["session_mode": completion.mode.rawValue]
      ),
      observedAt: Date(),
      authority: .assistantInference,
      confidence: 1,
      importance: 0.5,
      sensitivity: .personal,
      status: .active,
      retention: .persistent,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    let job = consolidator.map {
      _ in CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
    }
    try await store.saveEpisode(episode, enqueueing: job)
    episode = await runtime.indexAfterCanonicalWrite(episode)
    await runtime.emit(
      .init(kind: .episodePersisted, scope: scope, recordID: episode.id)
    )
    await consolidationWorker?.resume()
    return [
      CoreAgentPluginEvent(
        name: "memory_episode_persisted",
        message: "CoreAgent persisted the completed run as an episode.",
        attributes: ["record_id": episode.id.uuidString.lowercased()]
      )
    ]
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    []
  }

  @discardableResult
  public func remember(
    _ content: String,
    kind: CoreAgentMemoryKind = .fact,
    source: CoreAgentMemorySource = .init(kind: .application),
    authority: CoreAgentMemoryAuthority = .trustedApplication,
    confidence: Double = 1,
    importance: Double = 0.5,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    retention: CoreAgentMemoryRetention = .persistent
  ) async throws -> CoreAgentMemoryRecord {
    let record = try CoreAgentMemoryRecord(
      scope: scope,
      kind: kind,
      content: content,
      source: source,
      validFrom: validFrom,
      validUntil: validUntil,
      authority: authority,
      confidence: confidence,
      importance: importance,
      sensitivity: sensitivity,
      retention: retention,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    return try await runtime.persist(record)
  }

  @discardableResult
  public func correct(
    recordIDs: [UUID],
    with content: String,
    kind: CoreAgentMemoryKind = .fact,
    source: CoreAgentMemorySource = .init(kind: .correction),
    confidence: Double = 1,
    importance: Double = 1,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    retention: CoreAgentMemoryRetention = .persistent
  ) async throws -> CoreAgentMemoryRecord {
    let correction = try CoreAgentMemoryRecord(
      scope: scope,
      kind: kind,
      content: content,
      source: source,
      validFrom: validFrom,
      validUntil: validUntil,
      authority: .explicitUserCorrection,
      confidence: confidence,
      importance: importance,
      sensitivity: sensitivity,
      retention: retention,
      supersedes: recordIDs,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    try await store.applyCorrection(correction, superseding: recordIDs)
    for id in recordIDs {
      await runtime.removeDerivative(id: id)
      await runtime.emit(
        .init(
          kind: .recordSuperseded,
          scope: scope,
          recordID: id,
          attributes: ["superseded_by": correction.id.uuidString.lowercased()]
        )
      )
    }
    return await runtime.indexAfterCanonicalWrite(correction)
  }

  @discardableResult
  public func approve(_ candidateID: UUID) async throws -> CoreAgentMemoryRecord {
    try await runtime.approve(candidateID)
  }

  public func reject(_ candidateID: UUID, reason: String? = nil) async throws {
    try await runtime.reject(candidateID, reason: reason)
  }

  public func search(
    _ query: String,
    maximumResults: Int? = nil
  ) async throws -> [CoreAgentMemorySearchResult] {
    try await runtime.search(query: query, maximumResults: maximumResults)
  }

  public func pendingCandidates() async throws -> [CoreAgentMemoryCandidate] {
    try await store.candidates(in: scope, status: .pending)
  }

  public func consolidationFailures() async throws -> [CoreAgentMemoryConsolidationJob] {
    try await store.consolidationJobs(in: scope, statuses: [.failed])
  }

  public func retryFailedConsolidation() async throws {
    try await consolidationWorker?.retryFailed()
  }

  public func resumeConsolidation() async {
    await consolidationWorker?.resume()
  }

  public func flush() async {
    await consolidationWorker?.flush()
  }

  public func forget(_ id: UUID, reason: String? = nil) async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    _ = try await store.tombstone(id: id, in: scope, reason: reason)
    await runtime.emit(.init(kind: .recordTombstoned, scope: scope, recordID: id))
    await runtime.removeDerivative(id: id)
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.remove(
        recordID: id,
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
  }

  public func purge(_ id: UUID) async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    if try await store.record(id: id, in: scope) != nil {
      _ = try await store.tombstone(id: id, in: scope, reason: "hard_purge")
    }
    await runtime.removeDerivative(id: id)
    try await store.purge(id: id, in: scope)
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.remove(
        recordID: id,
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
    await runtime.emit(.init(kind: .recordPurged, scope: scope, recordID: id))
  }

  public func purge() async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    for record in try await store.records(in: scope) where record.status != .tombstoned {
      _ = try await store.tombstone(id: record.id, in: scope, reason: "scope_purge")
    }
    await runtime.removeAllDerivatives()
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.removeAll(
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
    try await store.purge(scope: scope)
    await runtime.emit(.init(kind: .scopePurged, scope: scope))
  }

  public func rebuildIndexes() async throws {
    try await runtime.rebuildIndex()
  }

  @discardableResult
  public func exportMarkdown(
    to directory: URL,
    exportedAt: Date = Date(),
    configuration: CoreAgentMemoryMarkdownExportConfiguration = .default
  ) async throws -> CoreAgentMemoryMarkdownManifest {
    let directory = directory.standardizedFileURL
    try await store.registerExportDirectory(directory.path, in: scope)
    return try CoreAgentMemoryMarkdownExporter.export(
      records: try await store.records(in: scope),
      scope: scope,
      to: directory,
      exportedAt: exportedAt,
      configuration: configuration
    )
  }

  private static func captureEpisode(
    from completion: CoreAgentPluginCompletion
  ) -> EpisodeCapture? {
    var lines: [String] = []
    var entryIDs: [String] = []
    var assets: [String] = []
    var capturedResponse = false

    for entry in completion.transcriptEntries {
      switch entry {
      case .instructions, .reasoning:
        continue
      case .prompt(let prompt):
        entryIDs.append(prompt.id)
        let rendered = render(prompt.segments, assetReferences: &assets)
        if !rendered.isEmpty { lines.append("USER:\n\(rendered)") }
      case .toolCalls(let calls):
        let visibleCalls = calls.filter { $0.toolName != "coreagent_search_memory" }
        guard !visibleCalls.isEmpty else { continue }
        entryIDs.append(calls.id)
        for call in visibleCalls {
          lines.append("TOOL_CALL \(call.toolName):\n\(call.arguments.jsonString)")
        }
      case .toolOutput(let output):
        guard output.toolName != "coreagent_search_memory" else { continue }
        entryIDs.append(output.id)
        let rendered = render(output.segments, assetReferences: &assets)
        if !rendered.isEmpty {
          lines.append("TOOL_OUTPUT \(output.toolName):\n\(rendered)")
        }
      case .response(let response):
        entryIDs.append(response.id)
        let rendered = render(response.segments, assetReferences: &assets)
        if !rendered.isEmpty {
          lines.append("ASSISTANT:\n\(rendered)")
          capturedResponse = true
        }
      @unknown default:
        continue
      }
    }

    if !capturedResponse {
      let fallback: String
      if case .string(let value) = completion.rawContent.kind {
        fallback = value
      } else {
        fallback = completion.rawContent.jsonString
      }
      if !fallback.isEmpty { lines.append("ASSISTANT:\n\(fallback)") }
    }

    let content = lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { return nil }
    return EpisodeCapture(
      content: content,
      transcriptEntryIDs: entryIDs,
      assetReferences: Array(Set(assets)).sorted()
    )
  }

  private static func render(
    _ segments: [Transcript.Segment],
    assetReferences: inout [String]
  ) -> String {
    segments.compactMap { segment -> String? in
      switch segment {
      case .text(let text):
        return text.content
      case .structure(let structure):
        return structure.content.jsonString
      case .attachment(let attachment):
        let reference: String
        switch attachment.content {
        case .image(let image):
          reference = image.url?.absoluteString ?? "attachment:\(attachment.id)"
        @unknown default:
          reference = "attachment:\(attachment.id)"
        }
        assetReferences.append(reference)
        return "[asset id=\(attachment.id) reference=\(reference)]"
      case .custom(let custom):
        return "[custom segment id=\(custom.id)]"
      @unknown default:
        return nil
      }
    }.joined(separator: "\n")
  }
}

private struct EpisodeCapture: Sendable {
  let content: String
  let transcriptEntryIDs: [String]
  let assetReferences: [String]
}

actor CoreAgentMemoryRuntime {
  let scope: CoreAgentMemoryScope
  let hasIndex: Bool

  private let store: any CoreAgentMemoryStore
  private let index: (any CoreAgentMemoryIndex)?
  private let disclosurePolicy: CoreAgentMemoryDisclosurePolicy
  private let retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration
  private let observers: [any CoreAgentMemoryObserver]

  init(
    scope: CoreAgentMemoryScope,
    store: any CoreAgentMemoryStore,
    index: (any CoreAgentMemoryIndex)?,
    disclosurePolicy: CoreAgentMemoryDisclosurePolicy,
    retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration,
    observers: [any CoreAgentMemoryObserver]
  ) {
    self.scope = scope
    self.store = store
    self.index = index
    self.hasIndex = index != nil
    self.disclosurePolicy = disclosurePolicy
    self.retrievalConfiguration = retrievalConfiguration
    self.observers = observers
  }

  func persist(_ record: CoreAgentMemoryRecord) async throws -> CoreAgentMemoryRecord {
    try await store.save(record)
    return await indexAfterCanonicalWrite(record)
  }

  func approve(_ candidateID: UUID) async throws -> CoreAgentMemoryRecord {
    guard let candidate = try await store.candidate(id: candidateID, in: scope) else {
      throw CoreAgentMemoryError.candidateNotFound(candidateID)
    }
    guard candidate.status == .pending else {
      throw CoreAgentMemoryError.invalidCandidateDecision
    }
    guard let episode = try await store.record(id: candidate.sourceRecordID, in: scope) else {
      throw CoreAgentMemoryError.recordNotFound(candidate.sourceRecordID)
    }
    let draft = candidate.draft
    let record = try CoreAgentMemoryRecord(
      scope: scope,
      kind: draft.kind,
      content: draft.content,
      source: CoreAgentMemorySource(
        kind: .conversation,
        runID: episode.source.runID,
        transcriptEntryIDs: episode.source.transcriptEntryIDs,
        assetReferences: episode.source.assetReferences,
        metadata: ["candidate_id": candidate.id.uuidString.lowercased()]
      ),
      observedAt: episode.observedAt,
      validFrom: draft.validFrom,
      validUntil: draft.validUntil,
      authority: draft.authority,
      confidence: draft.confidence,
      importance: draft.importance,
      sensitivity: draft.sensitivity,
      indexState: hasIndex ? .pending : .notConfigured
    )
    try await store.approveCandidate(id: candidateID, as: record, in: scope)
    let indexed = await indexAfterCanonicalWrite(record)
    await emit(
      .init(
        kind: .candidateApproved,
        scope: scope,
        recordID: indexed.id,
        candidateID: candidateID
      )
    )
    return indexed
  }

  func reject(_ candidateID: UUID, reason: String?) async throws {
    try await store.rejectCandidate(id: candidateID, in: scope, reason: reason)
    await emit(.init(kind: .candidateRejected, scope: scope, candidateID: candidateID))
  }

  func indexAfterCanonicalWrite(
    _ record: CoreAgentMemoryRecord
  ) async -> CoreAgentMemoryRecord {
    guard let index else { return record }
    var updated = record
    do {
      try await index.upsert(record)
      updated.indexState = .indexed
      updated.updatedAt = Date()
      try await store.save(updated)
      await emit(.init(kind: .indexingRepaired, scope: scope, recordID: record.id))
    } catch {
      updated.indexState = .failed
      updated.updatedAt = Date()
      try? await store.save(updated)
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          recordID: record.id,
          attributes: ["error_type": String(reflecting: Swift.type(of: error))]
        )
      )
    }
    return updated
  }

  func search(
    query: String,
    maximumResults: Int? = nil
  ) async throws -> [CoreAgentMemorySearchResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let maximum = min(
      max(1, maximumResults ?? retrievalConfiguration.maximumRecords),
      retrievalConfiguration.maximumRecords
    )
    let overfetch = maximum * retrievalConfiguration.overfetchMultiplier
    await emit(
      .init(
        kind: .retrievalStarted,
        scope: scope,
        attributes: ["maximum_results": String(maximum)]
      )
    )

    var relevance: [UUID: Double] = [:]
    let lexical = try await store.lexicalSearch(query: query, in: scope, limit: overfetch)
    merge(lexical, into: &relevance)
    if let index {
      do {
        let indexed = try await index.search(query: query, in: scope, limit: overfetch)
        merge(indexed, into: &relevance)
      } catch {
        await emit(
          .init(
            kind: .indexingFailed,
            scope: scope,
            attributes: [
              "operation": "search",
              "error_type": String(reflecting: Swift.type(of: error)),
            ]
          )
        )
      }
    }

    let orderedIDs = relevance.keys.sorted {
      let left = relevance[$0, default: 0]
      let right = relevance[$1, default: 0]
      if left != right { return left > right }
      return $0.uuidString < $1.uuidString
    }
    let now = Date()
    let canonical = try await store.records(ids: orderedIDs, in: scope)
    let filtered = canonical.filter {
      $0.status == .active
        && $0.isValid(at: now)
        && disclosurePolicy.allows($0.sensitivity)
    }
    let results = filtered.map {
      CoreAgentMemorySearchResult(record: $0, relevance: relevance[$0.id, default: 0])
    }.sorted(by: Self.resultsBefore).prefix(maximum).map { $0 }

    await emit(
      .init(
        kind: .retrievalFiltered,
        scope: scope,
        attributes: [
          "candidate_count": String(orderedIDs.count),
          "filtered_count": String(orderedIDs.count - filtered.count),
        ]
      )
    )
    await emit(
      .init(
        kind: .retrievalCompleted,
        scope: scope,
        attributes: ["record_count": String(results.count)]
      )
    )
    return results
  }

  func format(_ results: [CoreAgentMemorySearchResult]) -> String {
    CoreAgentMemoryContextFormatter.format(
      results,
      maximumCharacters: retrievalConfiguration.maximumCharacters
    )
  }

  func removeDerivative(id: UUID) async {
    guard let index else { return }
    do {
      try await index.remove(id: id, in: scope)
    } catch {
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          recordID: id,
          attributes: [
            "operation": "remove",
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
    }
  }

  func removeAllDerivatives() async {
    guard let index else { return }
    do {
      try await index.removeAll(in: scope)
    } catch {
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          attributes: [
            "operation": "remove_all",
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
    }
  }

  func rebuildIndex() async throws {
    guard let index else { return }
    try await index.removeAll(in: scope)
    let now = Date()
    for record in try await store.records(in: scope)
    where record.status == .active && record.isValid(at: now) {
      do {
        try await index.upsert(record)
        try await store.updateIndexState(.indexed, for: record.id, in: scope)
        await emit(.init(kind: .indexingRepaired, scope: scope, recordID: record.id))
      } catch {
        try? await store.updateIndexState(.failed, for: record.id, in: scope)
        await emit(
          .init(
            kind: .indexingFailed,
            scope: scope,
            recordID: record.id,
            attributes: ["error_type": String(reflecting: Swift.type(of: error))]
          )
        )
      }
    }
  }

  func emit(_ event: CoreAgentMemoryEvent) async {
    for observer in observers {
      await observer.memoryDidEmit(event)
    }
  }

  private func merge(
    _ candidates: [CoreAgentMemorySearchCandidate],
    into relevance: inout [UUID: Double]
  ) {
    for (index, candidate) in candidates.enumerated() {
      let reciprocalRank = 1 / Double(index + 1)
      relevance[candidate.id] = max(relevance[candidate.id, default: 0], reciprocalRank)
    }
  }

  private static func resultsBefore(
    _ lhs: CoreAgentMemorySearchResult,
    _ rhs: CoreAgentMemorySearchResult
  ) -> Bool {
    if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
    if lhs.record.authority.rank != rhs.record.authority.rank {
      return lhs.record.authority.rank > rhs.record.authority.rank
    }
    if lhs.record.observedAt != rhs.record.observedAt {
      return lhs.record.observedAt > rhs.record.observedAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
