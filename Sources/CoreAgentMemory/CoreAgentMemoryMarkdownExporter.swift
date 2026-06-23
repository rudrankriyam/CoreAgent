import Foundation

public struct CoreAgentMemoryMarkdownExportConfiguration: Sendable {
  public var fileProtection: CoreAgentMemoryFileProtection
  public var excludesFromBackup: Bool

  public init(
    fileProtection: CoreAgentMemoryFileProtection = .completeUntilFirstUserAuthentication,
    excludesFromBackup: Bool = true
  ) {
    self.fileProtection = fileProtection
    self.excludesFromBackup = excludesFromBackup
  }

  public static let `default` = CoreAgentMemoryMarkdownExportConfiguration()
}

public struct CoreAgentMemoryMarkdownManifest: Codable, Equatable, Sendable {
  public static let currentFormatVersion = 1

  public let formatVersion: Int
  public let scope: CoreAgentMemoryScope
  public let exportedAt: Date
  public var records: [Entry]

  public init(
    formatVersion: Int = currentFormatVersion,
    scope: CoreAgentMemoryScope,
    exportedAt: Date,
    records: [Entry]
  ) {
    self.formatVersion = formatVersion
    self.scope = scope
    self.exportedAt = exportedAt
    self.records = records
  }

  public struct Entry: Codable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let contentHash: String
    public let status: CoreAgentMemoryStatus

    public init(
      id: UUID,
      filename: String,
      contentHash: String,
      status: CoreAgentMemoryStatus
    ) {
      self.id = id
      self.filename = filename
      self.contentHash = contentHash
      self.status = status
    }
  }
}

public enum CoreAgentMemoryMarkdownExporter {
  public static let manifestFilename = "manifest.json"

  @discardableResult
  public static func export(
    records: [CoreAgentMemoryRecord],
    scope: CoreAgentMemoryScope,
    to directory: URL,
    exportedAt: Date = Date(),
    configuration: CoreAgentMemoryMarkdownExportConfiguration = .default
  ) throws -> CoreAgentMemoryMarkdownManifest {
    let directory = directory.standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let previous = try readManifestIfPresent(from: directory)
    if let previous, previous.scope != scope { throw CoreAgentMemoryError.scopeMismatch }

    let sortedRecords =
      records
      .filter { $0.scope == scope && $0.status != .tombstoned }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    let entries = sortedRecords.map { record in
      CoreAgentMemoryMarkdownManifest.Entry(
        id: record.id,
        filename: filename(for: record.id),
        contentHash: record.contentHash,
        status: record.status
      )
    }
    let currentFilenames = Set(entries.map(\.filename))
    for stale in previous?.records ?? [] where !currentFilenames.contains(stale.filename) {
      try removeIfPresent(directory.appending(path: stale.filename))
    }

    for record in sortedRecords {
      let url = directory.appending(path: filename(for: record.id))
      try Data(markdown(for: record).utf8).write(to: url, options: .atomic)
      try applyPolicies(to: url, configuration: configuration)
    }

    let manifest = CoreAgentMemoryMarkdownManifest(
      scope: scope,
      exportedAt: exportedAt,
      records: entries
    )
    try writeManifest(manifest, to: directory, configuration: configuration)
    try applyPolicies(to: directory, configuration: configuration)
    return manifest
  }

  public static func remove(
    recordID: UUID,
    scope: CoreAgentMemoryScope,
    from directory: URL,
    configuration: CoreAgentMemoryMarkdownExportConfiguration = .default
  ) throws {
    let directory = directory.standardizedFileURL
    guard var manifest = try readManifestIfPresent(from: directory) else {
      try removeIfPresent(directory.appending(path: filename(for: recordID)))
      return
    }
    guard manifest.scope == scope else { throw CoreAgentMemoryError.scopeMismatch }
    try removeIfPresent(directory.appending(path: filename(for: recordID)))
    manifest.records.removeAll { $0.id == recordID }
    try writeManifest(manifest, to: directory, configuration: configuration)
  }

  public static func removeAll(
    scope: CoreAgentMemoryScope,
    from directory: URL
  ) throws {
    let directory = directory.standardizedFileURL
    guard let manifest = try readManifestIfPresent(from: directory) else { return }
    guard manifest.scope == scope else { throw CoreAgentMemoryError.scopeMismatch }
    for entry in manifest.records {
      try removeIfPresent(directory.appending(path: entry.filename))
    }
    try removeIfPresent(directory.appending(path: manifestFilename))
  }

  private static func markdown(for record: CoreAgentMemoryRecord) -> String {
    let runID = record.source.runID?.uuidString.lowercased() ?? "none"
    let validFrom = record.validFrom.map(format) ?? "none"
    let validUntil = record.validUntil.map(format) ?? "none"
    let supersedes = record.supersedes.map { $0.uuidString.lowercased() }.sorted()
      .joined(separator: ", ")
    let transcriptIDs = record.source.transcriptEntryIDs.sorted().joined(separator: ", ")
    let assets = record.source.assetReferences.sorted().joined(separator: "\n")
    return """
      # Memory \(record.id.uuidString.lowercased())

      - Kind: \(record.kind.rawValue)
      - Status: \(record.status.rawValue)
      - Authority: \(record.authority.rawValue)
      - Sensitivity: \(record.sensitivity.rawValue)
      - Confidence: \(record.confidence)
      - Importance: \(record.importance)
      - Observed: \(format(record.observedAt))
      - Valid from: \(validFrom)
      - Valid until: \(validUntil)
      - Source: \(record.source.kind.rawValue)
      - Source run: \(runID)
      - Transcript entries: \(transcriptIDs.isEmpty ? "none" : transcriptIDs)
      - Supersedes: \(supersedes.isEmpty ? "none" : supersedes)
      - Content SHA-256: \(record.contentHash)

      ## Content

      \(record.content)

      ## Asset references

      \(assets.isEmpty ? "None." : assets)
      """ + "\n"
  }

  private static func writeManifest(
    _ manifest: CoreAgentMemoryMarkdownManifest,
    to directory: URL,
    configuration: CoreAgentMemoryMarkdownExportConfiguration
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let url = directory.appending(path: manifestFilename)
    try encoder.encode(manifest).write(to: url, options: .atomic)
    try applyPolicies(to: url, configuration: configuration)
  }

  private static func readManifestIfPresent(
    from directory: URL
  ) throws -> CoreAgentMemoryMarkdownManifest? {
    let url = directory.appending(path: manifestFilename)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(CoreAgentMemoryMarkdownManifest.self, from: Data(contentsOf: url))
  }

  private static func filename(for id: UUID) -> String {
    id.uuidString.lowercased() + ".md"
  }

  private static func format(_ date: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
  }

  private static func removeIfPresent(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private static func applyPolicies(
    to url: URL,
    configuration: CoreAgentMemoryMarkdownExportConfiguration
  ) throws {
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      let protection: FileProtectionType?
      switch configuration.fileProtection {
      case .complete: protection = .complete
      case .completeUnlessOpen: protection = .completeUnlessOpen
      case .completeUntilFirstUserAuthentication:
        protection = .completeUntilFirstUserAuthentication
      case .none: protection = nil
      }
      if let protection {
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
