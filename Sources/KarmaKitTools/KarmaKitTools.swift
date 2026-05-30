import Foundation
import KarmaKit

public enum KarmaToolError: Error, CustomStringConvertible, Equatable, Sendable {
  case missingArgument(String)
  case invalidPath(String)
  case pathNotAllowed(String)
  case fileTooLarge(path: String, maximumBytes: Int)
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
    case .fileTooLarge(let path, let maximumBytes):
      return "File exceeds \(maximumBytes) bytes: \(path)"
    case .unsupportedExpression(let expression):
      return "Unsupported expression: \(expression)"
    case .divisionByZero:
      return "Division by zero."
    }
  }
}

public struct CurrentTimeTool: Tool {
  public var name = "current_time"
  public var description = "Returns the current date and time in ISO 8601 format."
  public var inputs: [String: ToolInput] = [:]

  private let now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  public func call(arguments: [String: String]) async throws -> String {
    ISO8601DateFormatter().string(from: now())
  }
}

public struct MathTool: Tool {
  public var name = "calculate"
  public var description = "Evaluates a basic arithmetic expression with +, -, *, /, and parentheses."
  public var inputs: [String: ToolInput] = [
    "expression": ToolInput(type: .string, description: "Arithmetic expression to evaluate.")
  ]

  public init() {}

  public func call(arguments: [String: String]) async throws -> String {
    guard let expression = arguments["expression"] else {
      throw KarmaToolError.missingArgument("expression")
    }

    var parser = MathExpressionParser(expression)
    let value = try parser.parse()
    if value.rounded() == value {
      return String(Int(value))
    }
    return String(value)
  }
}

public struct FileReadTool: Tool {
  public var name = "read_file"
  public var description = "Reads a UTF-8 text file from an allowed directory."
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
      throw KarmaToolError.missingArgument("path")
    }

    let fileURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()

    guard isAllowed(fileURL) else {
      throw KarmaToolError.pathNotAllowed(fileURL.path)
    }

    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw KarmaToolError.invalidPath(fileURL.path)
    }

    if let fileSize = values.fileSize, fileSize > maximumBytes {
      throw KarmaToolError.fileTooLarge(path: fileURL.path, maximumBytes: maximumBytes)
    }

    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func isAllowed(_ fileURL: URL) -> Bool {
    allowedDirectories.contains { directory in
      fileURL.path == directory.path || fileURL.path.hasPrefix(directory.path + "/")
    }
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
      throw KarmaToolError.unsupportedExpression(original)
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
          throw KarmaToolError.divisionByZero
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
        throw KarmaToolError.unsupportedExpression(original)
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
      throw KarmaToolError.unsupportedExpression(original)
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
