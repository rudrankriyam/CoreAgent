import CryptoKit
import Foundation

actor CoreAgentMemoryConsolidationWorker {
  private let scope: CoreAgentMemoryScope
  private let store: any CoreAgentMemoryStore
  private let consolidator: any CoreAgentMemoryConsolidator
  private let approvalProvider: any CoreAgentMemoryApprovalProvider
  private let runtime: CoreAgentMemoryRuntime

  private var task: Task<Void, Never>?

  init(
    scope: CoreAgentMemoryScope,
    store: any CoreAgentMemoryStore,
    consolidator: any CoreAgentMemoryConsolidator,
    approvalProvider: any CoreAgentMemoryApprovalProvider,
    runtime: CoreAgentMemoryRuntime
  ) {
    self.scope = scope
    self.store = store
    self.consolidator = consolidator
    self.approvalProvider = approvalProvider
    self.runtime = runtime
  }

  func resume() {
    guard task == nil else { return }
    task = Task { [weak self] in
      await self?.drain()
    }
  }

  func flush() async {
    resume()
    while let current = task {
      await current.value
    }
  }

  func retryFailed() async throws {
    let failed = try await store.consolidationJobs(in: scope, statuses: [.failed])
    for var job in failed {
      job.status = .queued
      job.attemptCount = 0
      job.lastError = nil
      job.updatedAt = Date()
      try await store.save(job)
    }
    resume()
  }

  private func drain() async {
    while !Task.isCancelled {
      let jobs: [CoreAgentMemoryConsolidationJob]
      do {
        jobs = try await store.consolidationJobs(
          in: scope,
          statuses: [.queued, .processing]
        )
      } catch {
        await runtime.emit(
          .init(
            kind: .consolidationFailed,
            scope: scope,
            attributes: [
              "stage": "load_queue",
              "error_type": String(reflecting: Swift.type(of: error)),
            ]
          )
        )
        task = nil
        return
      }

      guard let job = jobs.first else {
        task = nil
        return
      }
      await process(job)
    }
    task = nil
  }

  private func process(_ original: CoreAgentMemoryConsolidationJob) async {
    var job = original
    guard job.attemptCount < job.maximumAttempts else {
      job.status = .failed
      job.lastError = job.lastError ?? "The consolidation attempt limit was reached."
      job.updatedAt = Date()
      try? await store.save(job)
      await runtime.emit(
        .init(
          kind: .consolidationFailed,
          scope: scope,
          recordID: job.episodeID,
          jobID: job.id,
          attributes: ["terminal": "true", "stage": "attempt_limit"]
        )
      )
      return
    }
    job.status = .processing
    job.attemptCount += 1
    job.updatedAt = Date()

    do {
      try await store.save(job)
      await runtime.emit(
        .init(
          kind: .consolidationStarted,
          scope: scope,
          recordID: job.episodeID,
          jobID: job.id,
          attributes: ["attempt": String(job.attemptCount)]
        )
      )
      guard let episode = try await store.record(id: job.episodeID, in: scope) else {
        throw CoreAgentMemoryError.recordNotFound(job.episodeID)
      }
      guard episode.isActive else {
        job.status = .cancelled
        job.lastError = "The source episode is not active."
        job.updatedAt = Date()
        try await store.save(job)
        await runtime.emit(
          .init(
            kind: .consolidationCancelled,
            scope: scope,
            recordID: job.episodeID,
            jobID: job.id,
            attributes: ["source_status": episode.status.rawValue]
          )
        )
        return
      }
      let drafts = try await consolidator.consolidate(episode: episode)
      for draft in drafts where draft.kind != .episode {
        try await propose(draft, from: episode, job: job)
      }
      job.status = .completed
      job.lastError = nil
      job.updatedAt = Date()
      try await store.save(job)
      await runtime.emit(
        .init(
          kind: .consolidationCompleted,
          scope: scope,
          recordID: job.episodeID,
          jobID: job.id,
          attributes: ["candidate_count": String(drafts.count)]
        )
      )
    } catch {
      job.status = job.attemptCount < job.maximumAttempts ? .queued : .failed
      job.lastError = String(describing: error)
      job.updatedAt = Date()
      try? await store.save(job)
      await runtime.emit(
        .init(
          kind: .consolidationFailed,
          scope: scope,
          recordID: job.episodeID,
          jobID: job.id,
          attributes: [
            "attempt": String(job.attemptCount),
            "terminal": String(job.status == .failed),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
    }
  }

  private func propose(
    _ draft: CoreAgentMemoryCandidateDraft,
    from episode: CoreAgentMemoryRecord,
    job: CoreAgentMemoryConsolidationJob
  ) async throws {
    guard let currentEpisode = try await store.record(id: episode.id, in: scope),
      currentEpisode.isActive
    else {
      throw CoreAgentMemoryError.sourceRecordInactive(episode.id)
    }
    let id = Self.candidateID(episodeID: episode.id, draft: draft)
    let candidate: CoreAgentMemoryCandidate
    if let existing = try await store.candidate(id: id, in: scope) {
      guard existing.status == .pending else { return }
      candidate = existing
    } else {
      candidate = CoreAgentMemoryCandidate(
        id: id,
        scope: scope,
        sourceRecordID: episode.id,
        draft: draft
      )
      try await store.save(candidate)
      await runtime.emit(
        .init(
          kind: .candidateProposed,
          scope: scope,
          recordID: episode.id,
          candidateID: candidate.id,
          jobID: job.id
        )
      )
    }

    let decision: CoreAgentMemoryApprovalDecision
    do {
      decision = try await approvalProvider.decision(for: candidate)
    } catch {
      await runtime.emit(
        .init(
          kind: .consolidationFailed,
          scope: scope,
          recordID: episode.id,
          candidateID: candidate.id,
          jobID: job.id,
          attributes: [
            "stage": "approval",
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
      return
    }

    switch decision {
    case .approve:
      _ = try await runtime.approve(candidate.id)
    case .reject(let reason):
      try await runtime.reject(candidate.id, reason: reason)
    case .deferDecision:
      break
    }
  }

  private static func candidateID(
    episodeID: UUID,
    draft: CoreAgentMemoryCandidateDraft
  ) -> UUID {
    let seed = [
      episodeID.uuidString.lowercased(),
      draft.kind.rawValue,
      CoreAgentMemoryRecord.hash(draft.content),
    ].joined(separator: "\u{0}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}
