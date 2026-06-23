import CryptoKit
import Foundation

public enum CoreAgentMemoryError: Error, LocalizedError, Sendable {
  case invalidScopeComponent(String)
  case emptyContent
  case recordNotFound(UUID)
  case candidateNotFound(UUID)
  case consolidationJobNotFound(UUID)
  case invalidCandidateDecision
  case sqlite(String)
  case unsupportedSchemaVersion(Int32)
  case exportFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidScopeComponent(let component):
      "Memory scope requires a nonempty \(component)."
    case .emptyContent:
      "Memory content must not be empty."
    case .recordNotFound(let id):
      "Memory record \(id.uuidString.lowercased()) was not found."
    case .candidateNotFound(let id):
      "Memory candidate \(id.uuidString.lowercased()) was not found."
    case .consolidationJobNotFound(let id):
      "Memory consolidation job \(id.uuidString.lowercased()) was not found."
    case .invalidCandidateDecision:
      "Only pending memory candidates can be approved or rejected."
    case .sqlite(let message):
      "SQLite memory store failed: \(message)"
    case .unsupportedSchemaVersion(let version):
      "The memory database schema version \(version) is not supported."
    case .exportFailed(let message):
      "Memory export failed: \(message)"
    }
  }
}

public struct CoreAgentMemoryScope: Codable, Hashable, Sendable {
  public let applicationID: String
  public let userID: String
  public let agentID: String

  public init(applicationID: String, userID: String, agentID: String) throws {
    let applicationID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
    let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !applicationID.isEmpty else {
      throw CoreAgentMemoryError.invalidScopeComponent("application identifier")
    }
    guard !userID.isEmpty else {
      throw CoreAgentMemoryError.invalidScopeComponent("user identifier")
    }
    guard !agentID.isEmpty else {
      throw CoreAgentMemoryError.invalidScopeComponent("agent identifier")
    }
    self.applicationID = applicationID
    self.userID = userID
    self.agentID = agentID
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      applicationID: container.decode(String.self, forKey: .applicationID),
      userID: container.decode(String.self, forKey: .userID),
      agentID: container.decode(String.self, forKey: .agentID)
    )
  }
}

public enum CoreAgentMemoryKind: String, Codable, CaseIterable, Sendable {
  case episode
  case fact
  case preference
  case procedure
  case reflection
}

public enum CoreAgentMemoryAuthority: String, Codable, CaseIterable, Sendable {
  case assistantInference
  case priorUserStatement
  case trustedApplication
  case trustedTool
  case explicitUserCorrection

  public var rank: Int {
    switch self {
    case .assistantInference: 0
    case .priorUserStatement: 1
    case .trustedApplication, .trustedTool: 2
    case .explicitUserCorrection: 3
    }
  }
}

public enum CoreAgentMemorySensitivity: String, Codable, CaseIterable, Sendable {
  case general
  case personal
  case restricted
}

public enum CoreAgentMemoryStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case active
  case superseded
  case tombstoned
}

public enum CoreAgentMemoryRetention: Codable, Equatable, Sendable {
  case persistent
  case until(Date)
  case episodeOnly
}

public enum CoreAgentMemoryIndexState: String, Codable, CaseIterable, Sendable {
  case notConfigured
  case pending
  case indexed
  case failed
}

public enum CoreAgentMemorySourceKind: String, Codable, CaseIterable, Sendable {
  case conversation
  case application
  case tool
  case correction
  case importFile
}

public struct CoreAgentMemorySource: Codable, Equatable, Sendable {
  public var kind: CoreAgentMemorySourceKind
  public var runID: UUID?
  public var transcriptEntryIDs: [String]
  public var toolName: String?
  public var assetReferences: [String]
  public var metadata: [String: String]

  public init(
    kind: CoreAgentMemorySourceKind,
    runID: UUID? = nil,
    transcriptEntryIDs: [String] = [],
    toolName: String? = nil,
    assetReferences: [String] = [],
    metadata: [String: String] = [:]
  ) {
    self.kind = kind
    self.runID = runID
    self.transcriptEntryIDs = transcriptEntryIDs
    self.toolName = toolName
    self.assetReferences = assetReferences
    self.metadata = metadata
  }
}

public struct CoreAgentMemoryRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var scope: CoreAgentMemoryScope
  public var kind: CoreAgentMemoryKind
  public var content: String
  public var source: CoreAgentMemorySource
  public var observedAt: Date
  public var validFrom: Date?
  public var validUntil: Date?
  public var authority: CoreAgentMemoryAuthority
  public var confidence: Double
  public var importance: Double
  public var sensitivity: CoreAgentMemorySensitivity
  public var status: CoreAgentMemoryStatus
  public var retention: CoreAgentMemoryRetention
  public var contentHash: String
  public var supersedes: [UUID]
  public var supersededBy: UUID?
  public var indexState: CoreAgentMemoryIndexState
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    scope: CoreAgentMemoryScope,
    kind: CoreAgentMemoryKind,
    content: String,
    source: CoreAgentMemorySource,
    observedAt: Date = Date(),
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    authority: CoreAgentMemoryAuthority,
    confidence: Double = 1,
    importance: Double = 0.5,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    status: CoreAgentMemoryStatus = .active,
    retention: CoreAgentMemoryRetention = .persistent,
    contentHash: String? = nil,
    supersedes: [UUID] = [],
    supersededBy: UUID? = nil,
    indexState: CoreAgentMemoryIndexState = .notConfigured,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) throws {
    let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw CoreAgentMemoryError.emptyContent }
    self.id = id
    self.scope = scope
    self.kind = kind
    self.content = content
    self.source = source
    self.observedAt = observedAt
    self.validFrom = validFrom
    self.validUntil = validUntil
    self.authority = authority
    self.confidence = min(max(confidence, 0), 1)
    self.importance = min(max(importance, 0), 1)
    self.sensitivity = sensitivity
    self.status = status
    self.retention = retention
    self.contentHash = contentHash ?? Self.hash(content)
    self.supersedes = supersedes
    self.supersededBy = supersededBy
    self.indexState = indexState
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  public var isActive: Bool { status == .active }

  public func isValid(at date: Date) -> Bool {
    if let validFrom, validFrom > date { return false }
    if let validUntil, validUntil <= date { return false }
    if case .until(let expiration) = retention, expiration <= date { return false }
    return true
  }

  public static func hash(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public enum CoreAgentMemoryCandidateStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case approved
  case rejected
}

public struct CoreAgentMemoryCandidateDraft: Codable, Equatable, Sendable {
  public var kind: CoreAgentMemoryKind
  public var content: String
  public var authority: CoreAgentMemoryAuthority
  public var confidence: Double
  public var importance: Double
  public var sensitivity: CoreAgentMemorySensitivity
  public var validFrom: Date?
  public var validUntil: Date?

  public init(
    kind: CoreAgentMemoryKind,
    content: String,
    authority: CoreAgentMemoryAuthority = .assistantInference,
    confidence: Double = 0.5,
    importance: Double = 0.5,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil
  ) throws {
    let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { throw CoreAgentMemoryError.emptyContent }
    self.kind = kind
    self.content = content
    self.authority = authority
    self.confidence = min(max(confidence, 0), 1)
    self.importance = min(max(importance, 0), 1)
    self.sensitivity = sensitivity
    self.validFrom = validFrom
    self.validUntil = validUntil
  }
}

public struct CoreAgentMemoryCandidate: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var scope: CoreAgentMemoryScope
  public var sourceRecordID: UUID
  public var draft: CoreAgentMemoryCandidateDraft
  public var status: CoreAgentMemoryCandidateStatus
  public var createdAt: Date
  public var decidedAt: Date?
  public var decisionReason: String?

  public init(
    id: UUID = UUID(),
    scope: CoreAgentMemoryScope,
    sourceRecordID: UUID,
    draft: CoreAgentMemoryCandidateDraft,
    status: CoreAgentMemoryCandidateStatus = .pending,
    createdAt: Date = Date(),
    decidedAt: Date? = nil,
    decisionReason: String? = nil
  ) {
    self.id = id
    self.scope = scope
    self.sourceRecordID = sourceRecordID
    self.draft = draft
    self.status = status
    self.createdAt = createdAt
    self.decidedAt = decidedAt
    self.decisionReason = decisionReason
  }
}

public enum CoreAgentMemoryConsolidationJobStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case processing
  case completed
  case failed
}

public struct CoreAgentMemoryConsolidationJob: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var scope: CoreAgentMemoryScope
  public var episodeID: UUID
  public var status: CoreAgentMemoryConsolidationJobStatus
  public var attemptCount: Int
  public var maximumAttempts: Int
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    scope: CoreAgentMemoryScope,
    episodeID: UUID,
    status: CoreAgentMemoryConsolidationJobStatus = .queued,
    attemptCount: Int = 0,
    maximumAttempts: Int = 3,
    lastError: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.scope = scope
    self.episodeID = episodeID
    self.status = status
    self.attemptCount = max(0, attemptCount)
    self.maximumAttempts = max(1, maximumAttempts)
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

public struct CoreAgentMemorySearchCandidate: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let score: Double

  public init(id: UUID, score: Double) {
    self.id = id
    self.score = score
  }
}

public struct CoreAgentMemorySearchResult: Equatable, Sendable, Identifiable {
  public var id: UUID { record.id }
  public let record: CoreAgentMemoryRecord
  public let relevance: Double

  public init(record: CoreAgentMemoryRecord, relevance: Double) {
    self.record = record
    self.relevance = relevance
  }
}

public enum CoreAgentMemoryModelDestination: String, Codable, Sendable {
  case onDevice
  case remote
}

public struct CoreAgentMemoryDisclosurePolicy: Sendable {
  public let destination: CoreAgentMemoryModelDestination
  public let allowedSensitivities: Set<CoreAgentMemorySensitivity>

  public init(
    destination: CoreAgentMemoryModelDestination,
    allowedSensitivities: Set<CoreAgentMemorySensitivity>? = nil
  ) {
    self.destination = destination
    self.allowedSensitivities =
      allowedSensitivities
      ?? {
        switch destination {
        case .onDevice: Set(CoreAgentMemorySensitivity.allCases)
        case .remote: [.general, .personal]
        }
      }()
  }

  public func allows(_ sensitivity: CoreAgentMemorySensitivity) -> Bool {
    allowedSensitivities.contains(sensitivity)
  }
}

public struct CoreAgentMemoryRetrievalConfiguration: Sendable {
  public var maximumRecords: Int
  public var maximumCharacters: Int
  public var overfetchMultiplier: Int

  public init(
    maximumRecords: Int = 8,
    maximumCharacters: Int = 6_000,
    overfetchMultiplier: Int = 4
  ) {
    self.maximumRecords = max(1, maximumRecords)
    self.maximumCharacters = max(256, maximumCharacters)
    self.overfetchMultiplier = max(1, overfetchMultiplier)
  }

  public static let `default` = CoreAgentMemoryRetrievalConfiguration()
}

public struct CoreAgentMemoryTombstone: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { recordID }
  public let recordID: UUID
  public let scope: CoreAgentMemoryScope
  public let deletedAt: Date
  public let reason: String?

  public init(
    recordID: UUID,
    scope: CoreAgentMemoryScope,
    deletedAt: Date = Date(),
    reason: String? = nil
  ) {
    self.recordID = recordID
    self.scope = scope
    self.deletedAt = deletedAt
    self.reason = reason
  }
}
