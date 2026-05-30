import Foundation
import CoreAgent

public enum CoreAgentToolError: Error, CustomStringConvertible, Equatable, Sendable {
  case missingArgument(String)
  case invalidPath(String)
  case pathNotAllowed(String)
  case invalidURL(String)
  case urlSchemeNotAllowed(String)
  case urlHostNotAllowed(String)
  case urlHostBlocked(String)
  case fileTooLarge(path: String, maximumBytes: Int)
  case responseTooLarge(url: String, maximumBytes: Int)
  case invalidHTTPStatus(url: String, statusCode: Int)
  case queryTooShort
  case unsupportedExpression(String)
  case divisionByZero

  public var description: String {
    switch self {
    case .missingArgument(let name):
      return "Missing required argument '\(name)'."
    case .invalidPath(let path):
      return "Invalid path '\(path)'."
    case .pathNotAllowed(let path):
      return "Path is outside the allowed directories: \(path)"
    case .invalidURL(let url):
      return "Invalid URL: \(url)"
    case .urlSchemeNotAllowed(let scheme):
      return "URL scheme is not allowed: \(scheme)"
    case .urlHostNotAllowed(let host):
      return "URL host is not allowed: \(host)"
    case .urlHostBlocked(let host):
      return "URL host is blocked: \(host)"
    case .fileTooLarge(let path, let maximumBytes):
      return "File exceeds \(maximumBytes) bytes: \(path)"
    case .responseTooLarge(let url, let maximumBytes):
      return "Response exceeds \(maximumBytes) bytes: \(url)"
    case .invalidHTTPStatus(let url, let statusCode):
      return "URL returned HTTP \(statusCode): \(url)"
    case .queryTooShort:
      return "Search query is too short."
    case .unsupportedExpression(let expression):
      return "Unsupported expression: \(expression)"
    case .divisionByZero:
      return "Division by zero."
    }
  }
}

public struct URLFetchTool: ToolOutputDescribing {
  public struct Response: Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
      self.statusCode = statusCode
      self.body = body
    }
  }

  public var name = "fetch_url"
  public var description = "Fetches a public HTTP(S) URL after validating scheme, host, timeout, and response size."
  public var outputDescription: String? = "UTF-8 response body from an allowed public URL."
  public var inputs: [String: ToolInput] = [
    "url": ToolInput(type: .string, description: "Public HTTP(S) URL to fetch.")
  ]

  public var allowedSchemes: Set<String>
  public var allowedHosts: Set<String>?
  public var blockedHosts: Set<String>
  public var maximumBytes: Int
  public var timeoutSeconds: Double
  private let client: @Sendable (URL, Double) async throws -> Response

  public init(
    allowedSchemes: Set<String> = ["https"],
    allowedHosts: Set<String>? = nil,
    blockedHosts: Set<String> = Self.defaultBlockedHosts,
    maximumBytes: Int = 128 * 1024,
    timeoutSeconds: Double = 20,
    client: (@Sendable (URL, Double) async throws -> Response)? = nil
  ) {
    self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
    self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
    self.blockedHosts = Set(blockedHosts.map { $0.lowercased() })
    self.maximumBytes = maximumBytes
    self.timeoutSeconds = timeoutSeconds
    self.client = client ?? Self.defaultClient
  }

  public func call(arguments: [String: String]) async throws -> String {
    guard let rawURL = arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else {
      throw CoreAgentToolError.missingArgument("url")
    }

    let url = try validate(rawURL)
    let response = try await client(url, timeoutSeconds)
    guard (200..<300).contains(response.statusCode) else {
      throw CoreAgentToolError.invalidHTTPStatus(url: url.absoluteString, statusCode: response.statusCode)
    }
    guard response.body.count <= maximumBytes else {
      throw CoreAgentToolError.responseTooLarge(url: url.absoluteString, maximumBytes: maximumBytes)
    }

    return String(decoding: response.body, as: UTF8.self)
  }

  private func validate(_ rawURL: String) throws -> URL {
    guard let components = URLComponents(string: rawURL),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          let url = components.url,
          !host.isEmpty else {
      throw CoreAgentToolError.invalidURL(rawURL)
    }

    guard allowedSchemes.contains(scheme) else {
      throw CoreAgentToolError.urlSchemeNotAllowed(scheme)
    }

    guard allowedHosts?.contains(host) ?? true else {
      throw CoreAgentToolError.urlHostNotAllowed(host)
    }

    guard !isBlockedHost(host) else {
      throw CoreAgentToolError.urlHostBlocked(host)
    }

    return url
  }

  private func isBlockedHost(_ host: String) -> Bool {
    if blockedHosts.contains(host) || host.hasSuffix(".local") {
      return true
    }

    if isBlockedIPv4(host) || isBlockedIPv6(host) {
      return true
    }

    return false
  }

  private func isBlockedIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".")
    guard parts.count == 4,
          let first = UInt8(parts[0]),
          let second = UInt8(parts[1]) else {
      return false
    }

    return first == 0
      || first == 10
      || first == 127
      || (first == 169 && second == 254)
      || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168)
  }

  private func isBlockedIPv6(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    return normalized == "::1"
      || normalized.hasPrefix("fc")
      || normalized.hasPrefix("fd")
      || normalized.hasPrefix("fe80:")
  }

  private static func defaultClient(url: URL, timeoutSeconds: Double) async throws -> Response {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeoutSeconds
    configuration.timeoutIntervalForResource = timeoutSeconds
    let session = URLSession(configuration: configuration)
    let (data, response) = try await session.data(from: url)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
    return Response(statusCode: statusCode, body: data)
  }

  public static let defaultBlockedHosts: Set<String> = [
    "localhost",
    "metadata.google.internal"
  ]
}

public struct CurrentTimeTool: ToolOutputDescribing {
  public var name = "current_time"
  public var description = "Returns the current date and time in ISO 8601 format."
  public var outputDescription: String? = "Current date and time as an ISO 8601 timestamp."
  public var inputs: [String: ToolInput] = [:]

  private let now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  public func call(arguments: [String: String]) async throws -> String {
    ISO8601DateFormatter().string(from: now())
  }
}

public struct MathTool: ToolOutputDescribing {
  public var name = "calculate"
  public var description = "Evaluates a basic arithmetic expression with +, -, *, /, and parentheses."
  public var outputDescription: String? = "The numeric result of the arithmetic expression."
  public var inputs: [String: ToolInput] = [
    "expression": ToolInput(type: .string, description: "Arithmetic expression to evaluate.")
  ]

  public init() {}

  public func call(arguments: [String: String]) async throws -> String {
    guard let expression = arguments["expression"] else {
      throw CoreAgentToolError.missingArgument("expression")
    }

    var parser = MathExpressionParser(expression)
    let value = try parser.parse()
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(value)
  }
}

public struct FileReadTool: ToolOutputDescribing {
  public var name = "read_file"
  public var description = "Reads a UTF-8 text file from an allowed directory."
  public var outputDescription: String? = "The UTF-8 file contents."
  public var inputs: [String: ToolInput] = [
    "path": ToolInput(type: .string, description: "Path to the text file.")
  ]

  public var allowedDirectories: [URL]
  public var maximumBytes: Int

  public init(allowedDirectories: [URL], maximumBytes: Int = 64 * 1024) {
    self.allowedDirectories = allowedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    self.maximumBytes = maximumBytes
  }

  public func call(arguments: [String: String]) async throws -> String {
    guard let path = arguments["path"], !path.isEmpty else {
      throw CoreAgentToolError.missingArgument("path")
    }

    let fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()

    guard isAllowed(fileURL) else {
      throw CoreAgentToolError.pathNotAllowed(fileURL.path)
    }

    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw CoreAgentToolError.invalidPath(fileURL.path)
    }

    if let fileSize = values.fileSize, fileSize > maximumBytes {
      throw CoreAgentToolError.fileTooLarge(path: fileURL.path, maximumBytes: maximumBytes)
    }

    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func isAllowed(_ fileURL: URL) -> Bool {
    allowedDirectories.contains { directory in
      fileURL.path == directory.path || fileURL.path.hasPrefix(directory.path + "/")
    }
  }
}

public struct SearchFilesTool: ToolOutputDescribing {
  public var name = "search_files"
  public var description = "Searches UTF-8 text files in allowed directories and returns JSON snippets."
  public var outputDescription: String? = "A JSON array of matching file paths, line numbers, and excerpts."
  public var inputs: [String: ToolInput] = [
    "query": ToolInput(type: .string, description: "Text to search for."),
    "max_results": ToolInput(type: .integer, description: "Maximum number of matches to return.", isRequired: false)
  ]

  public var allowedDirectories: [URL]
  public var maximumFileBytes: Int
  public var defaultMaximumResults: Int
  public var allowedExtensions: Set<String>

  public init(
    allowedDirectories: [URL],
    maximumFileBytes: Int = 128 * 1024,
    defaultMaximumResults: Int = 8,
    allowedExtensions: Set<String> = ["txt", "md", "swift", "json", "yaml", "yml"]
  ) {
    self.allowedDirectories = allowedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    self.maximumFileBytes = maximumFileBytes
    self.defaultMaximumResults = defaultMaximumResults
    self.allowedExtensions = allowedExtensions
  }

  public func call(arguments: [String: String]) async throws -> String {
    guard let query = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
      throw CoreAgentToolError.missingArgument("query")
    }
    guard query.count >= 2 else {
      throw CoreAgentToolError.queryTooShort
    }

    let maximumResults = arguments["max_results"].flatMap(Int.init) ?? defaultMaximumResults
    let normalizedQuery = query.lowercased()
    var results: [SearchResult] = []

    for fileURL in try searchableFiles() {
      let text = try String(contentsOf: fileURL, encoding: .utf8)
      for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated()
        where line.lowercased().contains(normalizedQuery) {
        results.append(
          SearchResult(
            path: fileURL.path,
            line: lineIndex + 1,
            excerpt: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
          )
        )

        if results.count >= maximumResults {
          return try encode(results)
        }
      }
    }

    return try encode(results)
  }

  private func searchableFiles() throws -> [URL] {
    var files: [URL] = []

    for directory in allowedDirectories {
      guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        continue
      }

      for case let fileURL as URL in enumerator {
        guard isAllowed(fileURL), isAllowedExtension(fileURL) else {
          continue
        }

        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
          continue
        }
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
          continue
        }

        files.append(fileURL)
      }
    }

    return files
  }

  private func isAllowed(_ fileURL: URL) -> Bool {
    let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
    return allowedDirectories.contains { directory in
      resolvedURL.path == directory.path || resolvedURL.path.hasPrefix(directory.path + "/")
    }
  }

  private func isAllowedExtension(_ fileURL: URL) -> Bool {
    let fileExtension = fileURL.pathExtension.lowercased()
    return allowedExtensions.isEmpty || allowedExtensions.contains(fileExtension)
  }

  private func encode(_ results: [SearchResult]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(results)
    return String(decoding: data, as: UTF8.self)
  }
}

public struct SearchResult: Codable, Equatable, Sendable {
  public var path: String
  public var line: Int
  public var excerpt: String

  public init(path: String, line: Int, excerpt: String) {
    self.path = path
    self.line = line
    self.excerpt = excerpt
  }
}

private struct MathExpressionParser {
  private var characters: [Character]
  private var index: Int = 0
  private let original: String

  init(_ expression: String) {
    self.original = expression
    self.characters = Array(expression)
  }

  mutating func parse() throws -> Double {
    let value = try parseExpression()
    skipSpaces()
    guard index == characters.count else {
      throw CoreAgentToolError.unsupportedExpression(original)
    }
    return value
  }

  private mutating func parseExpression() throws -> Double {
    var value = try parseTerm()
    while true {
      skipSpaces()
      if consume("+") {
        value += try parseTerm()
      } else if consume("-") {
        value -= try parseTerm()
      } else {
        return value
      }
    }
  }

  private mutating func parseTerm() throws -> Double {
    var value = try parseFactor()
    while true {
      skipSpaces()
      if consume("*") {
        value *= try parseFactor()
      } else if consume("/") {
        let divisor = try parseFactor()
        guard divisor != 0 else {
          throw CoreAgentToolError.divisionByZero
        }
        value /= divisor
      } else {
        return value
      }
    }
  }

  private mutating func parseFactor() throws -> Double {
    skipSpaces()
    if consume("-") {
      return try -parseFactor()
    }
    if consume("(") {
      let value = try parseExpression()
      guard consume(")") else {
        throw CoreAgentToolError.unsupportedExpression(original)
      }
      return value
    }
    return try parseNumber()
  }

  private mutating func parseNumber() throws -> Double {
    skipSpaces()
    let start = index
    while index < characters.count, characters[index].isNumber || characters[index] == "." {
      index += 1
    }
    guard start != index, let value = Double(String(characters[start..<index])) else {
      throw CoreAgentToolError.unsupportedExpression(original)
    }
    return value
  }

  private mutating func skipSpaces() {
    while index < characters.count, characters[index].isWhitespace {
      index += 1
    }
  }

  private mutating func consume(_ character: Character) -> Bool {
    guard index < characters.count, characters[index] == character else {
      return false
    }
    index += 1
    return true
  }
}
