import CryptoKit
import Foundation
import FoundationModels

public struct CoreAgentCheckpoint: Codable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let savedAt: Date
  public let compatibilityRevision: String
  public let transcript: Transcript

  public init(
    formatVersion: Int = Self.currentFormatVersion,
    savedAt: Date = Date(),
    compatibilityRevision: String,
    transcript: Transcript
  ) {
    self.formatVersion = formatVersion
    self.savedAt = savedAt
    self.compatibilityRevision = compatibilityRevision
    self.transcript = transcript
  }
}

public protocol CoreAgentCheckpointStore: Sendable {
  func loadCheckpoint(for key: String) async throws -> CoreAgentCheckpoint?
  func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) async throws
  func removeCheckpoint(for key: String) async throws
}

public enum CoreAgentFileCheckpointTypeErasurePolicy: Sendable {
  /// Reject content that Foundation Models cannot restore with concrete Swift types.
  case rejectLossyContent
  /// Allow Foundation Models to decode custom content into erased representations.
  case allowFoundationModelsTypeErasure
}

public enum CoreAgentCheckpointStoreError: Error, LocalizedError, Sendable {
  case customSegmentRequiresRehydration(entryID: String)
  case typedMetadataRequiresRehydration(entryID: String)
  case unsupportedTranscriptEntry

  public var errorDescription: String? {
    switch self {
    case .customSegmentRequiresRehydration(let entryID):
      "Checkpoint entry '\(entryID)' contains a custom segment that requires a rehydration codec."
    case .typedMetadataRequiresRehydration(let entryID):
      "Checkpoint entry '\(entryID)' contains typed metadata that cannot be restored losslessly."
    case .unsupportedTranscriptEntry:
      "The checkpoint contains a transcript entry this CoreAgent version cannot validate."
    }
  }
}

public actor InMemoryCheckpointStore: CoreAgentCheckpointStore {
  private var checkpoints: [String: CoreAgentCheckpoint]

  public init(checkpoints: [String: CoreAgentCheckpoint] = [:]) {
    self.checkpoints = checkpoints
  }

  public func loadCheckpoint(for key: String) -> CoreAgentCheckpoint? {
    checkpoints[key]
  }

  public func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) {
    checkpoints[key] = checkpoint
  }

  public func removeCheckpoint(for key: String) {
    checkpoints.removeValue(forKey: key)
  }
}

public actor FileCheckpointStore: CoreAgentCheckpointStore {
  private let directory: URL
  private let fileManager: FileManager
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy

  public init(
    directory: URL,
    fileManager: FileManager = .default,
    typeErasurePolicy: CoreAgentFileCheckpointTypeErasurePolicy = .rejectLossyContent
  ) {
    self.directory = directory
    self.fileManager = fileManager
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
    self.typeErasurePolicy = typeErasurePolicy
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  public func loadCheckpoint(for key: String) throws -> CoreAgentCheckpoint? {
    let url = fileURL(for: key)
    guard fileManager.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    let checkpoint = try decoder.decode(CoreAgentCheckpoint.self, from: data)
    try validateForFilePersistence(checkpoint)
    return checkpoint
  }

  public func saveCheckpoint(_ checkpoint: CoreAgentCheckpoint, for key: String) throws {
    try validateForFilePersistence(checkpoint)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(checkpoint)
    try data.write(to: fileURL(for: key), options: .atomic)
  }

  public func removeCheckpoint(for key: String) throws {
    let url = fileURL(for: key)
    guard fileManager.fileExists(atPath: url.path) else {
      return
    }
    try fileManager.removeItem(at: url)
  }

  private func fileURL(for key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appending(
      path: "\(digest).coreagent-transcript.json", directoryHint: .notDirectory)
  }

  private func validateForFilePersistence(_ checkpoint: CoreAgentCheckpoint) throws {
    guard case .rejectLossyContent = typeErasurePolicy else {
      return
    }

    for entry in checkpoint.transcript {
      switch entry {
      case .instructions(let instructions):
        try validate(segments: instructions.segments, entryID: instructions.id)
      case .prompt(let prompt):
        guard prompt.metadata.isEmpty else {
          throw CoreAgentCheckpointStoreError.typedMetadataRequiresRehydration(entryID: prompt.id)
        }
        try validate(segments: prompt.segments, entryID: prompt.id)
      case .toolCalls(let calls):
        for call in calls where !call.metadata.isEmpty {
          throw CoreAgentCheckpointStoreError.typedMetadataRequiresRehydration(entryID: call.id)
        }
      case .toolOutput(let output):
        try validate(segments: output.segments, entryID: output.id)
      case .response(let response):
        guard response.metadata.isEmpty else {
          throw CoreAgentCheckpointStoreError.typedMetadataRequiresRehydration(entryID: response.id)
        }
        try validate(segments: response.segments, entryID: response.id)
      case .reasoning(let reasoning):
        guard reasoning.metadata.isEmpty else {
          throw CoreAgentCheckpointStoreError.typedMetadataRequiresRehydration(
            entryID: reasoning.id)
        }
        try validate(segments: reasoning.segments, entryID: reasoning.id)
      @unknown default:
        throw CoreAgentCheckpointStoreError.unsupportedTranscriptEntry
      }
    }
  }

  private func validate(segments: [Transcript.Segment], entryID: String) throws {
    guard
      !segments.contains(where: { segment in
        if case .custom = segment { return true }
        return false
      })
    else {
      throw CoreAgentCheckpointStoreError.customSegmentRequiresRehydration(entryID: entryID)
    }
  }
}

public enum CoreAgentTranscriptRetention: Sendable {
  case complete
  case latestHistoryEntries(Int)
  case custom(@Sendable (Transcript) async throws -> Transcript)

  func validate() throws {
    if case .latestHistoryEntries(let count) = self, count < 0 {
      throw CoreAgentError.invalidHistoryLimit(count)
    }
  }

  func prepareForPersistence(_ transcript: Transcript) async throws -> Transcript {
    switch self {
    case .complete:
      return transcript
    case .latestHistoryEntries(let count):
      guard transcript.history.count > count else {
        return transcript
      }
      var retained = transcript
      let completeTurns = Self.completeTurns(in: transcript.history)
      var retainedTurns: [[Transcript.Entry]] = []
      var retainedCount = 0
      for turn in completeTurns.reversed() {
        guard retainedCount + turn.count <= count else {
          break
        }
        retainedTurns.append(turn)
        retainedCount += turn.count
      }
      retained.history = ArraySlice(retainedTurns.reversed().flatMap { $0 })
      return retained
    case .custom(let transform):
      return try await transform(transcript)
    }
  }

  private static func completeTurns(
    in history: ArraySlice<Transcript.Entry>
  ) -> [[Transcript.Entry]] {
    var turns: [[Transcript.Entry]] = []
    var current: [Transcript.Entry] = []

    for entry in history {
      if case .prompt = entry {
        if !current.isEmpty {
          turns.append(current)
        }
        current = [entry]
      } else if !current.isEmpty {
        current.append(entry)
      }
    }
    if !current.isEmpty {
      turns.append(current)
    }
    return turns
  }
}
