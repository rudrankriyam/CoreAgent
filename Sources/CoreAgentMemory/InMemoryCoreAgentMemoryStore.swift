import Foundation

public actor InMemoryCoreAgentMemoryStore: CoreAgentMemoryStore {
  private var storedRecords: [UUID: CoreAgentMemoryRecord]
  private var storedCandidates: [UUID: CoreAgentMemoryCandidate]
  private var storedJobs: [UUID: CoreAgentMemoryConsolidationJob]
  private var storedTombstones: [UUID: CoreAgentMemoryTombstone]

  public init(
    records: [CoreAgentMemoryRecord] = [],
    candidates: [CoreAgentMemoryCandidate] = [],
    jobs: [CoreAgentMemoryConsolidationJob] = [],
    tombstones: [CoreAgentMemoryTombstone] = []
  ) {
    self.storedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    self.storedCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    self.storedJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    self.storedTombstones = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.id, $0) })
  }

  public func save(_ record: CoreAgentMemoryRecord) throws {
    try ensureScope(storedRecords[record.id]?.scope, equals: record.scope)
    storedRecords[record.id] = record
  }

  public func saveEpisode(
    _ episode: CoreAgentMemoryRecord,
    enqueueing job: CoreAgentMemoryConsolidationJob?
  ) throws {
    try ensureScope(storedRecords[episode.id]?.scope, equals: episode.scope)
    if let job {
      try ensureScope(storedJobs[job.id]?.scope, equals: job.scope)
      guard job.scope == episode.scope else { throw CoreAgentMemoryError.scopeMismatch }
    }
    storedRecords[episode.id] = episode
    if let job { storedJobs[job.id] = job }
  }

  public func applyCorrection(
    _ correction: CoreAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) throws {
    try ensureScope(storedRecords[correction.id]?.scope, equals: correction.scope)
    for id in recordIDs {
      guard var existing = storedRecords[id], existing.scope == correction.scope else {
        throw CoreAgentMemoryError.recordNotFound(id)
      }
      existing.status = .superseded
      existing.supersededBy = correction.id
      existing.updatedAt = Date()
      storedRecords[id] = existing
    }
    storedRecords[correction.id] = correction
  }

  public func record(id: UUID, in scope: CoreAgentMemoryScope) -> CoreAgentMemoryRecord? {
    storedRecords[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func records(ids: [UUID], in scope: CoreAgentMemoryScope) -> [CoreAgentMemoryRecord] {
    ids.compactMap { id in storedRecords[id].flatMap { $0.scope == scope ? $0 : nil } }
  }

  public func records(in scope: CoreAgentMemoryScope) -> [CoreAgentMemoryRecord] {
    storedRecords.values
      .filter { $0.scope == scope }
      .sorted(by: Self.recordsBefore)
  }

  public func lexicalSearch(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) -> [CoreAgentMemorySearchCandidate] {
    let terms = Self.terms(in: query)
    return storedRecords.values
      .filter { $0.scope == scope }
      .compactMap { record -> CoreAgentMemorySearchCandidate? in
        let haystack = record.content.lowercased()
        let matches = terms.reduce(into: 0) { count, term in
          if haystack.contains(term) { count += 1 }
        }
        guard terms.isEmpty || matches > 0 else { return nil }
        let relevance = terms.isEmpty ? 0 : Double(matches) / Double(terms.count)
        return CoreAgentMemorySearchCandidate(id: record.id, score: relevance)
      }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.id.uuidString < $1.id.uuidString
      }
      .prefix(max(0, limit))
      .map { $0 }
  }

  public func updateIndexState(
    _ state: CoreAgentMemoryIndexState,
    for id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard var record = storedRecords[id], record.scope == scope else {
      throw CoreAgentMemoryError.recordNotFound(id)
    }
    record.indexState = state
    record.updatedAt = Date()
    storedRecords[id] = record
  }

  public func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws -> CoreAgentMemoryTombstone {
    guard var record = storedRecords[id], record.scope == scope else {
      throw CoreAgentMemoryError.recordNotFound(id)
    }
    let tombstone = CoreAgentMemoryTombstone(recordID: id, scope: scope, reason: reason)
    record.status = .tombstoned
    record.updatedAt = tombstone.deletedAt
    storedRecords[id] = record
    storedTombstones[id] = tombstone
    return tombstone
  }

  public func tombstone(id: UUID, in scope: CoreAgentMemoryScope) -> CoreAgentMemoryTombstone? {
    storedTombstones[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func purge(id: UUID, in scope: CoreAgentMemoryScope) {
    guard storedRecords[id]?.scope == scope || storedTombstones[id]?.scope == scope else { return }
    storedRecords.removeValue(forKey: id)
    storedTombstones.removeValue(forKey: id)
    storedCandidates = storedCandidates.filter {
      $0.value.scope != scope || $0.value.sourceRecordID != id
    }
    storedJobs = storedJobs.filter { $0.value.scope != scope || $0.value.episodeID != id }
  }

  public func purge(scope: CoreAgentMemoryScope) {
    storedRecords = storedRecords.filter { $0.value.scope != scope }
    storedCandidates = storedCandidates.filter { $0.value.scope != scope }
    storedJobs = storedJobs.filter { $0.value.scope != scope }
    storedTombstones = storedTombstones.filter { $0.value.scope != scope }
  }

  public func save(_ candidate: CoreAgentMemoryCandidate) throws {
    try ensureScope(storedCandidates[candidate.id]?.scope, equals: candidate.scope)
    guard storedRecords[candidate.sourceRecordID]?.scope == candidate.scope else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    storedCandidates[candidate.id] = candidate
  }

  public func candidate(id: UUID, in scope: CoreAgentMemoryScope) -> CoreAgentMemoryCandidate? {
    storedCandidates[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func candidates(
    in scope: CoreAgentMemoryScope,
    status: CoreAgentMemoryCandidateStatus?
  ) -> [CoreAgentMemoryCandidate] {
    storedCandidates.values
      .filter { $0.scope == scope && (status == nil || $0.status == status) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  public func approveCandidate(
    id: UUID,
    as record: CoreAgentMemoryRecord,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard record.scope == scope else { throw CoreAgentMemoryError.scopeMismatch }
    guard var candidate = storedCandidates[id], candidate.scope == scope else {
      throw CoreAgentMemoryError.candidateNotFound(id)
    }
    guard candidate.status == .pending else {
      throw CoreAgentMemoryError.invalidCandidateDecision
    }
    candidate.status = .approved
    candidate.decidedAt = Date()
    storedCandidates[id] = candidate
    storedRecords[record.id] = record
  }

  public func rejectCandidate(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws {
    guard var candidate = storedCandidates[id], candidate.scope == scope else {
      throw CoreAgentMemoryError.candidateNotFound(id)
    }
    guard candidate.status == .pending else {
      throw CoreAgentMemoryError.invalidCandidateDecision
    }
    candidate.status = .rejected
    candidate.decidedAt = Date()
    candidate.decisionReason = reason
    storedCandidates[id] = candidate
  }

  public func save(_ job: CoreAgentMemoryConsolidationJob) throws {
    try ensureScope(storedJobs[job.id]?.scope, equals: job.scope)
    guard storedRecords[job.episodeID]?.scope == job.scope else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    storedJobs[job.id] = job
  }

  public func consolidationJob(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) -> CoreAgentMemoryConsolidationJob? {
    storedJobs[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func consolidationJobs(
    in scope: CoreAgentMemoryScope,
    statuses: Set<CoreAgentMemoryConsolidationJobStatus>
  ) -> [CoreAgentMemoryConsolidationJob] {
    storedJobs.values
      .filter { $0.scope == scope && statuses.contains($0.status) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }
  }

  private static func terms(in query: String) -> [String] {
    query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  private static func recordsBefore(
    _ lhs: CoreAgentMemoryRecord,
    _ rhs: CoreAgentMemoryRecord
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func ensureScope(
    _ existing: CoreAgentMemoryScope?,
    equals proposed: CoreAgentMemoryScope
  ) throws {
    guard existing == nil || existing == proposed else {
      throw CoreAgentMemoryError.scopeMismatch
    }
  }
}
