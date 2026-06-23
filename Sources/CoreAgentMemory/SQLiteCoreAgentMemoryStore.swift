import Foundation
import SQLite3

public enum CoreAgentMemoryFileProtection: Sendable {
  case complete
  case completeUnlessOpen
  case completeUntilFirstUserAuthentication
  case none
}

public struct SQLiteCoreAgentMemoryStoreConfiguration: Sendable {
  public var fileProtection: CoreAgentMemoryFileProtection
  public var excludesFromBackup: Bool

  public init(
    fileProtection: CoreAgentMemoryFileProtection = .completeUntilFirstUserAuthentication,
    excludesFromBackup: Bool = true
  ) {
    self.fileProtection = fileProtection
    self.excludesFromBackup = excludesFromBackup
  }

  public static let `default` = SQLiteCoreAgentMemoryStoreConfiguration()
}

public actor SQLiteCoreAgentMemoryStore: CoreAgentMemoryStore {
  public static let schemaVersion: Int32 = 1

  public let databaseURL: URL

  private let connection: SQLiteCoreAgentMemoryConnection
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let configuration: SQLiteCoreAgentMemoryStoreConfiguration

  public init(
    databaseURL: URL,
    configuration: SQLiteCoreAgentMemoryStoreConfiguration = .default
  ) throws {
    self.databaseURL = databaseURL.standardizedFileURL
    self.configuration = configuration

    try FileManager.default.createDirectory(
      at: self.databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    self.connection = try SQLiteCoreAgentMemoryConnection(url: self.databaseURL)
    self.encoder = JSONEncoder.coreAgentMemory
    self.decoder = JSONDecoder.coreAgentMemory

    try Self.configure(connection)
    try Self.applyFilePolicies(
      databaseURL: self.databaseURL,
      configuration: configuration
    )
  }

  public func save(_ record: CoreAgentMemoryRecord) throws {
    try transaction { try saveRecord(record) }
    try refreshFilePolicies()
  }

  public func saveEpisode(
    _ episode: CoreAgentMemoryRecord,
    enqueueing job: CoreAgentMemoryConsolidationJob?
  ) throws {
    try transaction {
      try saveRecord(episode)
      if let job { try saveJob(job) }
    }
    try refreshFilePolicies()
  }

  public func applyCorrection(
    _ correction: CoreAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) throws {
    try transaction {
      var existingRecords: [CoreAgentMemoryRecord] = []
      for id in recordIDs {
        guard let existing = try fetchRecord(id: id, scope: correction.scope) else {
          throw CoreAgentMemoryError.recordNotFound(id)
        }
        existingRecords.append(existing)
      }
      try saveRecord(correction)
      for var existing in existingRecords {
        existing.status = .superseded
        existing.supersededBy = correction.id
        existing.updatedAt = Date()
        try saveRecord(existing)
      }
    }
    try refreshFilePolicies()
  }

  public func record(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryRecord? {
    try fetchRecord(id: id, scope: scope)
  }

  public func records(
    ids: [UUID],
    in scope: CoreAgentMemoryScope
  ) throws -> [CoreAgentMemoryRecord] {
    try ids.compactMap { try fetchRecord(id: $0, scope: scope) }
  }

  public func records(in scope: CoreAgentMemoryScope) throws -> [CoreAgentMemoryRecord] {
    let statement = try prepare(
      """
      SELECT payload FROM memory_records
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    return try decodeRows(statement, as: CoreAgentMemoryRecord.self)
  }

  public func lexicalSearch(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) throws -> [CoreAgentMemorySearchCandidate] {
    guard limit > 0 else { return [] }
    let matchQuery = Self.ftsQuery(query)
    if matchQuery.isEmpty {
      let statement = try prepare(
        """
        SELECT id FROM memory_records
        WHERE application_id = ? AND user_id = ? AND agent_id = ?
        ORDER BY observed_at DESC, id ASC
        LIMIT ?
        """
      )
      try bind(scope, to: statement)
      try statement.bind(Int64(limit), at: 4)
      var results: [CoreAgentMemorySearchCandidate] = []
      while try statement.step() {
        guard let id = UUID(uuidString: statement.text(at: 0)) else { continue }
        results.append(CoreAgentMemorySearchCandidate(id: id, score: 0))
      }
      return results
    }

    let statement = try prepare(
      """
      SELECT memory_fts.record_id, -bm25(memory_fts) AS relevance
      FROM memory_fts
      JOIN memory_records ON memory_records.id = memory_fts.record_id
      WHERE memory_fts MATCH ?
        AND memory_records.application_id = ?
        AND memory_records.user_id = ?
        AND memory_records.agent_id = ?
      ORDER BY relevance DESC, memory_fts.record_id ASC
      LIMIT ?
      """
    )
    try statement.bind(matchQuery, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    try statement.bind(Int64(limit), at: 5)

    var results: [CoreAgentMemorySearchCandidate] = []
    while try statement.step() {
      guard let id = UUID(uuidString: statement.text(at: 0)) else { continue }
      results.append(
        CoreAgentMemorySearchCandidate(id: id, score: statement.double(at: 1))
      )
    }
    return results
  }

  public func updateIndexState(
    _ state: CoreAgentMemoryIndexState,
    for id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard var record = try fetchRecord(id: id, scope: scope) else {
      throw CoreAgentMemoryError.recordNotFound(id)
    }
    record.indexState = state
    record.updatedAt = Date()
    try save(record)
  }

  public func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws -> CoreAgentMemoryTombstone {
    let tombstone = CoreAgentMemoryTombstone(recordID: id, scope: scope, reason: reason)
    try transaction {
      guard var record = try fetchRecord(id: id, scope: scope) else {
        throw CoreAgentMemoryError.recordNotFound(id)
      }
      record.status = .tombstoned
      record.updatedAt = tombstone.deletedAt
      try saveRecord(record)
      try saveTombstone(tombstone)
      for var candidate in try candidates(in: scope, status: .pending)
      where candidate.sourceRecordID == id {
        candidate.status = .rejected
        candidate.decidedAt = tombstone.deletedAt
        candidate.decisionReason = "source_tombstoned"
        try saveCandidate(candidate)
      }
      for var job in try consolidationJobs(
        in: scope,
        statuses: [.queued, .processing, .failed]
      ) where job.episodeID == id {
        job.status = .cancelled
        job.lastError = "The source episode was tombstoned."
        job.updatedAt = tombstone.deletedAt
        try saveJob(job)
      }
    }
    try refreshFilePolicies()
    return tombstone
  }

  public func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryTombstone? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_tombstones
      WHERE record_id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryTombstone.self, from: statement.data(at: 0))
  }

  public func purge(id: UUID, in scope: CoreAgentMemoryScope) throws {
    try transaction {
      guard try fetchRecord(id: id, scope: scope) != nil else { return }
      for var linked in try records(in: scope) where linked.id != id {
        let previousSupersedes = linked.supersedes
        let previousSupersededBy = linked.supersededBy
        linked.supersedes.removeAll { $0 == id }
        if linked.supersededBy == id { linked.supersededBy = nil }
        if linked.supersedes != previousSupersedes
          || linked.supersededBy != previousSupersededBy
        {
          linked.updatedAt = Date()
          try saveRecord(linked)
        }
      }
      let fts = try prepare(
        """
        DELETE FROM memory_fts WHERE record_id IN (
          SELECT id FROM memory_records
          WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
        )
        """
      )
      try fts.bind(id, at: 1)
      try bind(scope, to: fts, startingAt: 2)
      try fts.run()

      let statement = try prepare(
        """
        DELETE FROM memory_records
        WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
        """
      )
      try statement.bind(id, at: 1)
      try bind(scope, to: statement, startingAt: 2)
      try statement.run()
    }
    try refreshFilePolicies()
  }

  public func purge(scope: CoreAgentMemoryScope) throws {
    try transaction {
      let fts = try prepare(
        """
        DELETE FROM memory_fts WHERE record_id IN (
          SELECT id FROM memory_records
          WHERE application_id = ? AND user_id = ? AND agent_id = ?
        )
        """
      )
      try bind(scope, to: fts)
      try fts.run()

      for table in [
        "memory_candidates", "memory_jobs", "memory_tombstones", "memory_exports",
        "memory_records",
      ] {
        let statement = try prepare(
          "DELETE FROM \(table) WHERE application_id = ? AND user_id = ? AND agent_id = ?"
        )
        try bind(scope, to: statement)
        try statement.run()
      }
    }
    try refreshFilePolicies()
  }

  public func save(_ candidate: CoreAgentMemoryCandidate) throws {
    try transaction { try saveCandidate(candidate) }
    try refreshFilePolicies()
  }

  public func candidate(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryCandidate? {
    try fetchCandidate(id: id, scope: scope)
  }

  public func candidates(
    in scope: CoreAgentMemoryScope,
    status: CoreAgentMemoryCandidateStatus?
  ) throws -> [CoreAgentMemoryCandidate] {
    let statusClause = status == nil ? "" : " AND status = ?"
    let statement = try prepare(
      """
      SELECT payload FROM memory_candidates
      WHERE application_id = ? AND user_id = ? AND agent_id = ?\(statusClause)
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    if let status { try statement.bind(status.rawValue, at: 4) }
    return try decodeRows(statement, as: CoreAgentMemoryCandidate.self)
  }

  public func approveCandidate(
    id: UUID,
    as record: CoreAgentMemoryRecord,
    in scope: CoreAgentMemoryScope
  ) throws {
    guard record.scope == scope else { throw CoreAgentMemoryError.scopeMismatch }
    try transaction {
      guard var candidate = try fetchCandidate(id: id, scope: scope) else {
        throw CoreAgentMemoryError.candidateNotFound(id)
      }
      guard candidate.status == .pending else {
        throw CoreAgentMemoryError.invalidCandidateDecision
      }
      guard let source = try fetchRecord(id: candidate.sourceRecordID, scope: scope),
        source.isActive
      else {
        throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
      }
      candidate.status = .approved
      candidate.decidedAt = Date()
      try saveCandidate(candidate)
      try saveRecord(record)
    }
    try refreshFilePolicies()
  }

  public func rejectCandidate(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) throws {
    try transaction {
      guard var candidate = try fetchCandidate(id: id, scope: scope) else {
        throw CoreAgentMemoryError.candidateNotFound(id)
      }
      guard candidate.status == .pending else {
        throw CoreAgentMemoryError.invalidCandidateDecision
      }
      candidate.status = .rejected
      candidate.decidedAt = Date()
      candidate.decisionReason = reason
      try saveCandidate(candidate)
    }
    try refreshFilePolicies()
  }

  public func save(_ job: CoreAgentMemoryConsolidationJob) throws {
    try transaction { try saveJob(job) }
    try refreshFilePolicies()
  }

  public func consolidationJob(
    id: UUID,
    in scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryConsolidationJob? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_jobs
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(
      CoreAgentMemoryConsolidationJob.self,
      from: statement.data(at: 0)
    )
  }

  public func consolidationJobs(
    in scope: CoreAgentMemoryScope,
    statuses: Set<CoreAgentMemoryConsolidationJobStatus>
  ) throws -> [CoreAgentMemoryConsolidationJob] {
    guard !statuses.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: statuses.count).joined(separator: ",")
    let statement = try prepare(
      """
      SELECT payload FROM memory_jobs
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
        AND status IN (\(placeholders))
      ORDER BY created_at ASC, id ASC
      """
    )
    try bind(scope, to: statement)
    for (offset, status) in statuses.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
      try statement.bind(status.rawValue, at: Int32(offset + 4))
    }
    return try decodeRows(statement, as: CoreAgentMemoryConsolidationJob.self)
  }

  public func registerExportDirectory(
    _ path: String,
    in scope: CoreAgentMemoryScope
  ) throws {
    let statement = try prepare(
      """
      INSERT OR REPLACE INTO memory_exports (
        application_id, user_id, agent_id, path, registered_at
      ) VALUES (?, ?, ?, ?, ?)
      """
    )
    try bind(scope, to: statement)
    try statement.bind(path, at: 4)
    try statement.bind(Date(), at: 5)
    try statement.run()
  }

  public func exportDirectories(in scope: CoreAgentMemoryScope) throws -> [String] {
    let statement = try prepare(
      """
      SELECT path FROM memory_exports
      WHERE application_id = ? AND user_id = ? AND agent_id = ?
      ORDER BY path ASC
      """
    )
    try bind(scope, to: statement)
    var paths: [String] = []
    while try statement.step() {
      paths.append(statement.text(at: 0))
    }
    return paths
  }

  private func fetchRecord(
    id: UUID,
    scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryRecord? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_records
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryRecord.self, from: statement.data(at: 0))
  }

  private func fetchCandidate(
    id: UUID,
    scope: CoreAgentMemoryScope
  ) throws -> CoreAgentMemoryCandidate? {
    let statement = try prepare(
      """
      SELECT payload FROM memory_candidates
      WHERE id = ? AND application_id = ? AND user_id = ? AND agent_id = ?
      """
    )
    try statement.bind(id, at: 1)
    try bind(scope, to: statement, startingAt: 2)
    guard try statement.step() else { return nil }
    return try decoder.decode(CoreAgentMemoryCandidate.self, from: statement.data(at: 0))
  }

  private func saveRecord(_ record: CoreAgentMemoryRecord) throws {
    try ensureScope(for: record.id, table: "memory_records", equals: record.scope)
    for linkedID in record.supersedes {
      guard try fetchRecord(id: linkedID, scope: record.scope) != nil else {
        throw CoreAgentMemoryError.scopeMismatch
      }
    }
    if let linkedID = record.supersededBy,
      try fetchRecord(id: linkedID, scope: record.scope) == nil
    {
      throw CoreAgentMemoryError.scopeMismatch
    }
    let statement = try prepare(
      """
      INSERT INTO memory_records (
        id, application_id, user_id, agent_id, kind, status, sensitivity, authority,
        observed_at, valid_from, valid_until, created_at, updated_at, content,
        content_hash, index_state, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        application_id = excluded.application_id,
        user_id = excluded.user_id,
        agent_id = excluded.agent_id,
        kind = excluded.kind,
        status = excluded.status,
        sensitivity = excluded.sensitivity,
        authority = excluded.authority,
        observed_at = excluded.observed_at,
        valid_from = excluded.valid_from,
        valid_until = excluded.valid_until,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        content = excluded.content,
        content_hash = excluded.content_hash,
        index_state = excluded.index_state,
        payload = excluded.payload
      """
    )
    try statement.bind(record.id, at: 1)
    try bind(record.scope, to: statement, startingAt: 2)
    try statement.bind(record.kind.rawValue, at: 5)
    try statement.bind(record.status.rawValue, at: 6)
    try statement.bind(record.sensitivity.rawValue, at: 7)
    try statement.bind(record.authority.rawValue, at: 8)
    try statement.bind(record.observedAt, at: 9)
    try statement.bind(record.validFrom, at: 10)
    try statement.bind(record.validUntil, at: 11)
    try statement.bind(record.createdAt, at: 12)
    try statement.bind(record.updatedAt, at: 13)
    try statement.bind(record.content, at: 14)
    try statement.bind(record.contentHash, at: 15)
    try statement.bind(record.indexState.rawValue, at: 16)
    try statement.bind(encoder.encode(record), at: 17)
    try statement.run()

    let deleteFTS = try prepare("DELETE FROM memory_fts WHERE record_id = ?")
    try deleteFTS.bind(record.id, at: 1)
    try deleteFTS.run()
    if record.status != .tombstoned {
      let insertFTS = try prepare("INSERT INTO memory_fts(record_id, content) VALUES (?, ?)")
      try insertFTS.bind(record.id, at: 1)
      try insertFTS.bind(record.content, at: 2)
      try insertFTS.run()
    }

    let deleteProvenance = try prepare("DELETE FROM memory_provenance WHERE record_id = ?")
    try deleteProvenance.bind(record.id, at: 1)
    try deleteProvenance.run()
    try saveProvenance(for: record)

    let deleteSupersessions = try prepare(
      "DELETE FROM memory_supersessions WHERE newer_record_id = ?"
    )
    try deleteSupersessions.bind(record.id, at: 1)
    try deleteSupersessions.run()
    for previousID in record.supersedes {
      let supersession = try prepare(
        """
        INSERT OR REPLACE INTO memory_supersessions (
          older_record_id, newer_record_id, created_at
        ) VALUES (?, ?, ?)
        """
      )
      try supersession.bind(previousID, at: 1)
      try supersession.bind(record.id, at: 2)
      try supersession.bind(record.updatedAt, at: 3)
      try supersession.run()
    }
  }

  private func saveProvenance(for record: CoreAgentMemoryRecord) throws {
    let transcriptIDs =
      record.source.transcriptEntryIDs.isEmpty
      ? [String?](arrayLiteral: nil)
      : record.source.transcriptEntryIDs.map(Optional.some)
    let assetReferences =
      record.source.assetReferences.isEmpty
      ? [String?](arrayLiteral: nil)
      : record.source.assetReferences.map(Optional.some)
    let rows: [(String?, String?)]
    if transcriptIDs == [nil], assetReferences == [nil] {
      rows = [(nil, nil)]
    } else {
      rows =
        transcriptIDs.filter { $0 != nil }.map { ($0, nil) }
        + assetReferences.filter { $0 != nil }.map { (nil, $0) }
    }
    let metadata = try encoder.encode(record.source.metadata)
    for (transcriptID, assetReference) in rows {
      let statement = try prepare(
        """
        INSERT INTO memory_provenance (
          record_id, source_kind, run_id, transcript_entry_id, tool_name,
          asset_reference, metadata
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
      )
      try statement.bind(record.id, at: 1)
      try statement.bind(record.source.kind.rawValue, at: 2)
      try statement.bind(record.source.runID?.uuidString.lowercased(), at: 3)
      try statement.bind(transcriptID, at: 4)
      try statement.bind(record.source.toolName, at: 5)
      try statement.bind(assetReference, at: 6)
      try statement.bind(metadata, at: 7)
      try statement.run()
    }
  }

  private func saveCandidate(_ candidate: CoreAgentMemoryCandidate) throws {
    try ensureScope(for: candidate.id, table: "memory_candidates", equals: candidate.scope)
    guard let source = try fetchRecord(id: candidate.sourceRecordID, scope: candidate.scope) else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || candidate.status == .rejected else {
      throw CoreAgentMemoryError.sourceRecordInactive(candidate.sourceRecordID)
    }
    let statement = try prepare(
      """
      INSERT INTO memory_candidates (
        id, application_id, user_id, agent_id, source_record_id, status, created_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        payload = excluded.payload
      """
    )
    try statement.bind(candidate.id, at: 1)
    try bind(candidate.scope, to: statement, startingAt: 2)
    try statement.bind(candidate.sourceRecordID, at: 5)
    try statement.bind(candidate.status.rawValue, at: 6)
    try statement.bind(candidate.createdAt, at: 7)
    try statement.bind(encoder.encode(candidate), at: 8)
    try statement.run()
  }

  private func saveJob(_ job: CoreAgentMemoryConsolidationJob) throws {
    try ensureScope(for: job.id, table: "memory_jobs", equals: job.scope)
    guard let source = try fetchRecord(id: job.episodeID, scope: job.scope) else {
      throw CoreAgentMemoryError.scopeMismatch
    }
    guard source.isActive || job.status == .cancelled else {
      throw CoreAgentMemoryError.sourceRecordInactive(job.episodeID)
    }
    let statement = try prepare(
      """
      INSERT INTO memory_jobs (
        id, application_id, user_id, agent_id, episode_id, status,
        attempt_count, created_at, updated_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        status = excluded.status,
        attempt_count = excluded.attempt_count,
        updated_at = excluded.updated_at,
        payload = excluded.payload
      """
    )
    try statement.bind(job.id, at: 1)
    try bind(job.scope, to: statement, startingAt: 2)
    try statement.bind(job.episodeID, at: 5)
    try statement.bind(job.status.rawValue, at: 6)
    try statement.bind(Int64(job.attemptCount), at: 7)
    try statement.bind(job.createdAt, at: 8)
    try statement.bind(job.updatedAt, at: 9)
    try statement.bind(encoder.encode(job), at: 10)
    try statement.run()
  }

  private func saveTombstone(_ tombstone: CoreAgentMemoryTombstone) throws {
    let statement = try prepare(
      """
      INSERT INTO memory_tombstones (
        record_id, application_id, user_id, agent_id, deleted_at, payload
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(record_id) DO UPDATE SET
        deleted_at = excluded.deleted_at,
        payload = excluded.payload
      """
    )
    try statement.bind(tombstone.recordID, at: 1)
    try bind(tombstone.scope, to: statement, startingAt: 2)
    try statement.bind(tombstone.deletedAt, at: 5)
    try statement.bind(encoder.encode(tombstone), at: 6)
    try statement.run()
  }

  private func decodeRows<Value: Decodable>(
    _ statement: SQLiteCoreAgentMemoryStatement,
    as type: Value.Type
  ) throws -> [Value] {
    var values: [Value] = []
    while try statement.step() {
      values.append(try decoder.decode(type, from: statement.data(at: 0)))
    }
    return values
  }

  private func bind(
    _ scope: CoreAgentMemoryScope,
    to statement: SQLiteCoreAgentMemoryStatement,
    startingAt index: Int32 = 1
  ) throws {
    try statement.bind(scope.applicationID, at: index)
    try statement.bind(scope.userID, at: index + 1)
    try statement.bind(scope.agentID, at: index + 2)
  }

  private func prepare(_ sql: String) throws -> SQLiteCoreAgentMemoryStatement {
    try connection.prepare(sql)
  }

  private func ensureScope(
    for id: UUID,
    table: String,
    equals scope: CoreAgentMemoryScope
  ) throws {
    let statement = try prepare(
      "SELECT application_id, user_id, agent_id FROM \(table) WHERE id = ?"
    )
    try statement.bind(id, at: 1)
    guard try statement.step() else { return }
    guard statement.text(at: 0) == scope.applicationID,
      statement.text(at: 1) == scope.userID,
      statement.text(at: 2) == scope.agentID
    else {
      throw CoreAgentMemoryError.scopeMismatch
    }
  }

  private func transaction<Value>(_ operation: () throws -> Value) throws -> Value {
    try connection.execute("BEGIN IMMEDIATE")
    do {
      let value = try operation()
      try connection.execute("COMMIT")
      return value
    } catch {
      try? connection.execute("ROLLBACK")
      throw error
    }
  }

  private func refreshFilePolicies() throws {
    try Self.applyFilePolicies(databaseURL: databaseURL, configuration: configuration)
  }

  private static func configure(_ connection: SQLiteCoreAgentMemoryConnection) throws {
    try connection.execute("PRAGMA foreign_keys = ON")
    try connection.execute("PRAGMA journal_mode = WAL")
    try connection.execute("PRAGMA synchronous = NORMAL")
    let version = try connection.int32(for: "PRAGMA user_version")
    guard version <= schemaVersion else {
      throw CoreAgentMemoryError.unsupportedSchemaVersion(version)
    }
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_records (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        sensitivity TEXT NOT NULL,
        authority TEXT NOT NULL,
        observed_at REAL NOT NULL,
        valid_from REAL,
        valid_until REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        content TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        index_state TEXT NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_records_scope ON memory_records(application_id, user_id, agent_id)"
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_records_status ON memory_records(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(record_id UNINDEXED, content, tokenize = 'unicode61')"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_provenance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        source_kind TEXT NOT NULL,
        run_id TEXT,
        transcript_entry_id TEXT,
        tool_name TEXT,
        asset_reference TEXT,
        metadata BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_supersessions (
        older_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        newer_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        PRIMARY KEY (older_record_id, newer_record_id)
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_candidates (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        source_record_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        created_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_candidates_scope ON memory_candidates(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_jobs (
        id TEXT PRIMARY KEY NOT NULL,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        episode_id TEXT NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      "CREATE INDEX IF NOT EXISTS memory_jobs_scope ON memory_jobs(application_id, user_id, agent_id, status)"
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_tombstones (
        record_id TEXT PRIMARY KEY NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        deleted_at REAL NOT NULL,
        payload BLOB NOT NULL
      )
      """
    )
    try connection.execute(
      """
      CREATE TABLE IF NOT EXISTS memory_exports (
        application_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        path TEXT NOT NULL,
        registered_at REAL NOT NULL,
        PRIMARY KEY (application_id, user_id, agent_id, path)
      )
      """
    )
    try connection.execute("PRAGMA user_version = \(schemaVersion)")
  }

  private static func ftsQuery(_ query: String) -> String {
    query.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " OR ")
  }

  private static func applyFilePolicies(
    databaseURL: URL,
    configuration: SQLiteCoreAgentMemoryStoreConfiguration
  ) throws {
    for url in [
      databaseURL,
      URL(fileURLWithPath: databaseURL.path + "-wal"),
      URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where FileManager.default.fileExists(atPath: url.path) {
      #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        if let protection = configuration.fileProtection.foundationValue {
          try FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: url.path
          )
        }
      #endif
      if configuration.excludesFromBackup {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
      }
    }
  }
}

extension CoreAgentMemoryFileProtection {
  fileprivate var foundationValue: FileProtectionType? {
    switch self {
    case .complete: .complete
    case .completeUnlessOpen: .completeUnlessOpen
    case .completeUntilFirstUserAuthentication: .completeUntilFirstUserAuthentication
    case .none: nil
    }
  }
}

private final class SQLiteCoreAgentMemoryConnection: @unchecked Sendable {
  private var database: OpaquePointer?

  init(url: URL) throws {
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close_v2(database)
      throw CoreAgentMemoryError.sqlite(message)
    }
    sqlite3_busy_timeout(database, 5_000)
  }

  deinit {
    sqlite3_close_v2(database)
  }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? lastError
      sqlite3_free(errorMessage)
      throw CoreAgentMemoryError.sqlite(message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteCoreAgentMemoryStatement {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw CoreAgentMemoryError.sqlite(lastError)
    }
    return SQLiteCoreAgentMemoryStatement(statement: statement, connection: self)
  }

  func int32(for sql: String) throws -> Int32 {
    let statement = try prepare(sql)
    guard try statement.step() else { return 0 }
    return statement.int32(at: 0)
  }

  var lastError: String {
    database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
  }
}

private final class SQLiteCoreAgentMemoryStatement {
  private let statement: OpaquePointer
  private let connection: SQLiteCoreAgentMemoryConnection

  init(statement: OpaquePointer, connection: SQLiteCoreAgentMemoryConnection) {
    self.statement = statement
    self.connection = connection
  }

  deinit {
    sqlite3_finalize(statement)
  }

  func bind(_ value: String?, at index: Int32) throws {
    let result: Int32
    if let value {
      result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    } else {
      result = sqlite3_bind_null(statement, index)
    }
    try check(result)
  }

  func bind(_ value: UUID, at index: Int32) throws {
    try bind(value.uuidString.lowercased(), at: index)
  }

  func bind(_ value: Int64, at index: Int32) throws {
    try check(sqlite3_bind_int64(statement, index, value))
  }

  func bind(_ value: Double, at index: Int32) throws {
    try check(sqlite3_bind_double(statement, index, value))
  }

  func bind(_ value: Date?, at index: Int32) throws {
    if let value {
      try bind(value.timeIntervalSince1970, at: index)
    } else {
      try check(sqlite3_bind_null(statement, index))
    }
  }

  func bind(_ value: Data, at index: Int32) throws {
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
    }
    try check(result)
  }

  func step() throws -> Bool {
    switch sqlite3_step(statement) {
    case SQLITE_ROW: true
    case SQLITE_DONE: false
    default: throw CoreAgentMemoryError.sqlite(connection.lastError)
    }
  }

  func run() throws {
    guard try !step() else {
      throw CoreAgentMemoryError.sqlite("A write statement unexpectedly returned a row.")
    }
  }

  func text(at index: Int32) -> String {
    guard let text = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: text)
  }

  func double(at index: Int32) -> Double {
    sqlite3_column_double(statement, index)
  }

  func int32(at index: Int32) -> Int32 {
    sqlite3_column_int(statement, index)
  }

  func data(at index: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, index))
    guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: bytes, count: count)
  }

  private func check(_ result: Int32) throws {
    guard result == SQLITE_OK else {
      throw CoreAgentMemoryError.sqlite(connection.lastError)
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension JSONEncoder {
  fileprivate static var coreAgentMemory: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var coreAgentMemory: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    return decoder
  }
}
