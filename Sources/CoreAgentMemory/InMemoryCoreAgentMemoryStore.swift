import Foundation

public actor InMemoryCoreAgentMemoryStore: CoreAgentMemoryStore {
  private var storedRecords: [UUID: CoreAgentMemoryRecord]
  private var storedCandidates: [UUID: CoreAgentMemoryCandidate]
  private var storedJobs: [UUID: CoreAgentMemoryConsolidationJob]
  private var claimedJobIDs: Set<UUID>
  private var storedTombstones: [UUID: CoreAgentMemoryTombstone]
  private var storedExportDirectories: [CoreAgentMemoryScope: Set<String>]

  public init(
    records: [CoreAgentMemoryRecord] = [],
    candidates: [CoreAgentMemoryCandidate] = [],
    jobs: [CoreAgentMemoryConsolidationJob] = [],
    tombstones: [CoreAgentMemoryTombstone] = []
  ) {
    self.storedRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    self.storedCandidates = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    self.storedJobs = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
    self.claimedJobIDs = []
    self.storedTombstones = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.id, $0) })
    self.storedExportDirectories = [:]
  }

  public func save(_ record: CoreAgentMemoryRecord) throws {
    try ensureScope(storedRecords[record.id]?.scope, equals: record.scope)
    try ensureLinkedRecordScopes(record)
    storedRecords[record.id] = record
  }

  public func saveEpisode(
    _ episode: CoreAgentMemoryRecord,
    enqueueing job: CoreAgentMemoryConsolidationJob?
  ) throws {
    try ensureScope(storedRecords[episode.id]?.scope, equals: episode.scope)
    try ensureLinkedRecordScopes(episode)
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
    var existingRecords: [CoreAgentMemoryRecord] = []
    for id in recordIDs {
      guard let existing = storedRecords[id], existing.scope == correction.scope else {
        throw CoreAgentMemoryError.recordNotFound(id)
      }
      existingRecords.append(existing)
    }
    try ensureLinkedRecordScopes(correction)
    storedRecords[correction.id] = correction
    for var existing in existingRecords {
      existing.status = .superseded
      existing.supersededBy = correction.id
      existing.updatedAt = Date()
      storedRecords[existing.id] = existing
    }
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
    for (candidateID, var candidate) in storedCandidates
    where candidate.scope == scope
      && candidate.sourceRecordID == id
      && candidate.status == .pending
    {
      candidate.status = .rejected
      candidate.decidedAt = tombstone.deletedAt
      candidate.decisionReason = "source_tombstoned"
      storedCandidates[candidateID] = candidate
    }
    for (jobID, var job) in storedJobs
    where job.scope == scope && job.episodeID == id && job.status != .completed {
      job.status = .cancelled
      job.lastError = "The source episode was tombstoned."
      job.updatedAt = tombstone.deletedAt
      storedJobs[jobID] = job
      claimedJobIDs.remove(jobID)
    }
    return tombstone
  }

  public func tombstone(id: UUID, in scope: CoreAgentMemoryScope) -> CoreAgentMemoryTombstone? {
    storedTombstones[id].flatMap { $0.scope == scope ? $0 : nil }
  }

  public func purge(id: UUID, in scope: CoreAgentMemoryScope) {
    guard storedRecords[id]?.scope == scope || storedTombstones[id]?.scope == scope else { return }
    for (linkedID, var linked) in Array(storedRecords) where linked.scope == scope {
      let previousCount = linked.supersedes.count
      linked.supersedes.removeAll { $0 == id }
      if linked.supersededBy == id { linked.supersededBy = nil }
      if linked.supersedes.count != previousCount || storedRecords[linkedID]?.supersededBy == id {
        linked.updatedAt = Date()
        storedRecords[linkedID] = linked
      }
    }
    storedRecords.removeValue(forKey: id)
    storedTombstones.removeValue(forKey: id)
    storedCandidates = storedCandidates.filter {
      $0.value.scope != scope || $0.value.sourceRecordID != id
    }
    let removedJobIDs = storedJobs.values
      .filter { $0.scope == scope && $0.episodeID == id }
      .map(\.id)
    storedJobs = storedJobs.filter { $0.value.scope != scope || $0.value.episodeID != id }
    claimedJobIDs.subtract(removedJobIDs)
  }

  public func purge(scope: CoreAgentMemoryScope) {
    claimedJobIDs.subtract(storedJobs.values.filter { $0.scope == scope }.map(\.id))
    storedRecords = storedRecords.filter { $0.value.scope != scope }
    storedCandidates = storedCandidates.filter { $0.value.scope != scope }
    storedJobs = storedJobs.filter { $0.value.scope != scope }
    storedTombstones = storedTombstones.filter { $0.value.scope != scope }
    storedExportDirectories.removeValue(forKey: scope)
  }

  public func save(_ candidate: CoreAgentMemoryCandidate) throws {
    try ensureScope(storedCandidates[candidate.id]?.scope, equals: candidate.scope)
    guard let source = storedRecords[candidate.sourceRecordID], source.scope == candidate.scope
    else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || candidate.status == .rejected else {
      throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
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
    try ensureScope(storedRecords[record.id]?.scope, equals: record.scope)
    try ensureLinkedRecordScopes(record)
    guard var candidate = storedCandidates[id], candidate.scope == scope else {
      throw CoreAgentMemoryError.candidateNotFound(id)
    }
    guard candidate.status == .pending else {
      throw CoreAgentMemoryError.invalidCandidateDecision
    }
    guard let source = storedRecords[candidate.sourceRecordID], source.isActive else {
      throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
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
    guard let source = storedRecords[job.episodeID], source.scope == job.scope else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || job.status == .cancelled else {
      throw CoreAgentMemoryError.sourceRecordInactive(job.episodeID)
    }
    storedJobs[job.id] = job
    if job.status != .processing {
      claimedJobIDs.remove(job.id)
    }
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

  public func claimNextConsolidationJob(
    in scope: CoreAgentMemoryScope
  ) -> CoreAgentMemoryConsolidationJob? {
    let jobs = storedJobs.values
      .filter {
        $0.scope == scope
          && ($0.status == .queued || $0.status == .processing)
          && !claimedJobIDs.contains($0.id)
      }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id.uuidString < $1.id.uuidString
      }

    for var job in jobs {
      guard storedRecords[job.episodeID]?.isActive == true else {
        job.status = .cancelled
        job.lastError = "The source episode is not active."
        job.updatedAt = Date()
        storedJobs[job.id] = job
        continue
      }
      job.status = .processing
      job.attemptCount += 1
      job.updatedAt = Date()
      storedJobs[job.id] = job
      claimedJobIDs.insert(job.id)
      return job
    }
    return nil
  }

  public func registerExportDirectory(_ path: String, in scope: CoreAgentMemoryScope) {
    storedExportDirectories[scope, default: []].insert(path)
  }

  public func exportDirectories(in scope: CoreAgentMemoryScope) -> [String] {
    storedExportDirectories[scope, default: []].sorted()
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

  private func ensureLinkedRecordScopes(_ record: CoreAgentMemoryRecord) throws {
    for id in record.supersedes {
      guard storedRecords[id]?.scope == record.scope else {
        throw CoreAgentMemoryError.scopeMismatch
      }
    }
    if let id = record.supersededBy,
      storedRecords[id]?.scope != record.scope
    {
      throw CoreAgentMemoryError.scopeMismatch
    }
  }
}
