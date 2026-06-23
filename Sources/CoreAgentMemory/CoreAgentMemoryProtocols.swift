import Foundation

public protocol CoreAgentMemoryStore: Sendable {
  func save(_ record: CoreAgentMemoryRecord) async throws
  func saveEpisode(
    _ episode: CoreAgentMemoryRecord,
    enqueueing job: CoreAgentMemoryConsolidationJob?
  ) async throws
  func applyCorrection(
    _ correction: CoreAgentMemoryRecord,
    superseding recordIDs: [UUID]
  ) async throws
  func record(id: UUID, in scope: CoreAgentMemoryScope) async throws -> CoreAgentMemoryRecord?
  func records(ids: [UUID], in scope: CoreAgentMemoryScope) async throws
    -> [CoreAgentMemoryRecord]
  func records(in scope: CoreAgentMemoryScope) async throws -> [CoreAgentMemoryRecord]
  func lexicalSearch(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) async throws -> [CoreAgentMemorySearchCandidate]
  func updateIndexState(
    _ state: CoreAgentMemoryIndexState,
    for id: UUID,
    in scope: CoreAgentMemoryScope
  ) async throws
  func tombstone(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) async throws -> CoreAgentMemoryTombstone
  func tombstone(id: UUID, in scope: CoreAgentMemoryScope) async throws
    -> CoreAgentMemoryTombstone?
  func purge(id: UUID, in scope: CoreAgentMemoryScope) async throws
  func purge(scope: CoreAgentMemoryScope) async throws

  func save(_ candidate: CoreAgentMemoryCandidate) async throws
  func candidate(id: UUID, in scope: CoreAgentMemoryScope) async throws
    -> CoreAgentMemoryCandidate?
  func candidates(
    in scope: CoreAgentMemoryScope,
    status: CoreAgentMemoryCandidateStatus?
  ) async throws -> [CoreAgentMemoryCandidate]
  func approveCandidate(
    id: UUID,
    as record: CoreAgentMemoryRecord,
    in scope: CoreAgentMemoryScope
  ) async throws
  func rejectCandidate(
    id: UUID,
    in scope: CoreAgentMemoryScope,
    reason: String?
  ) async throws

  func save(_ job: CoreAgentMemoryConsolidationJob) async throws
  func consolidationJob(id: UUID, in scope: CoreAgentMemoryScope) async throws
    -> CoreAgentMemoryConsolidationJob?
  func consolidationJobs(
    in scope: CoreAgentMemoryScope,
    statuses: Set<CoreAgentMemoryConsolidationJobStatus>
  ) async throws -> [CoreAgentMemoryConsolidationJob]
  /// Atomically moves one eligible job to processing and returns it to exactly one caller.
  func claimNextConsolidationJob(in scope: CoreAgentMemoryScope) async throws
    -> CoreAgentMemoryConsolidationJob?
  func registerExportDirectory(_ path: String, in scope: CoreAgentMemoryScope) async throws
  func exportDirectories(in scope: CoreAgentMemoryScope) async throws -> [String]
}

public protocol CoreAgentMemoryIndex: Sendable {
  func upsert(_ record: CoreAgentMemoryRecord) async throws
  func search(
    query: String,
    in scope: CoreAgentMemoryScope,
    limit: Int
  ) async throws -> [CoreAgentMemorySearchCandidate]
  func remove(id: UUID, in scope: CoreAgentMemoryScope) async throws
  func removeAll(in scope: CoreAgentMemoryScope) async throws
}

public protocol CoreAgentMemoryConsolidator: Sendable {
  func consolidate(episode: CoreAgentMemoryRecord) async throws
    -> [CoreAgentMemoryCandidateDraft]
}

public enum CoreAgentMemoryApprovalDecision: Sendable {
  case approve
  case reject(reason: String?)
  case deferDecision
}

public protocol CoreAgentMemoryApprovalProvider: Sendable {
  func decision(for candidate: CoreAgentMemoryCandidate) async throws
    -> CoreAgentMemoryApprovalDecision
}

public struct DeferCoreAgentMemoryApprovalProvider: CoreAgentMemoryApprovalProvider {
  public init() {}

  public func decision(for candidate: CoreAgentMemoryCandidate) -> CoreAgentMemoryApprovalDecision {
    .deferDecision
  }
}

public enum CoreAgentMemoryEventKind: String, Codable, Sendable {
  case retrievalStarted
  case retrievalFiltered
  case retrievalCompleted
  case contextInjected
  case episodePersisted
  case candidateProposed
  case candidateApproved
  case candidateRejected
  case recordSuperseded
  case indexingFailed
  case indexingRepaired
  case consolidationStarted
  case consolidationCompleted
  case consolidationFailed
  case consolidationCancelled
  case recordTombstoned
  case recordPurged
  case scopePurged
}

public struct CoreAgentMemoryEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let timestamp: Date
  public let kind: CoreAgentMemoryEventKind
  public let scope: CoreAgentMemoryScope
  public let recordID: UUID?
  public let candidateID: UUID?
  public let jobID: UUID?
  public let attributes: [String: String]

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    kind: CoreAgentMemoryEventKind,
    scope: CoreAgentMemoryScope,
    recordID: UUID? = nil,
    candidateID: UUID? = nil,
    jobID: UUID? = nil,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.scope = scope
    self.recordID = recordID
    self.candidateID = candidateID
    self.jobID = jobID
    self.attributes = attributes
  }
}

public protocol CoreAgentMemoryObserver: Sendable {
  func memoryDidEmit(_ event: CoreAgentMemoryEvent) async
}

public struct ClosureCoreAgentMemoryObserver: CoreAgentMemoryObserver {
  private let closure: @Sendable (CoreAgentMemoryEvent) async -> Void

  public init(_ closure: @escaping @Sendable (CoreAgentMemoryEvent) async -> Void) {
    self.closure = closure
  }

  public func memoryDidEmit(_ event: CoreAgentMemoryEvent) async {
    await closure(event)
  }
}
