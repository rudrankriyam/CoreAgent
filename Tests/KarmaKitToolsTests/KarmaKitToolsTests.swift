import Foundation
import Testing
import KarmaKit
@testable import KarmaKitTools

@Test func currentTimeToolReturnsISO8601Date() async throws {
  let tool = CurrentTimeTool(now: { Date(timeIntervalSince1970: 0) })
  let output = try await tool.call(arguments: [:])

  #expect(output == "1970-01-01T00:00:00Z")
}

@Test func mathToolEvaluatesArithmeticWithPrecedence() async throws {
  let tool = MathTool()
  let output = try await tool.call(arguments: ["expression": "2 + 3 * (4 + 1)"])

  #expect(output == "17")
}

@Test func mathToolRejectsDivisionByZero() async throws {
  let tool = MathTool()

  await #expect(throws: KarmaToolError.divisionByZero) {
    _ = try await tool.call(arguments: ["expression": "10 / 0"])
  }
}

@Test func mathToolRejectsUnsupportedExpression() async throws {
  let tool = MathTool()

  await #expect(throws: KarmaToolError.unsupportedExpression("2 ** 8")) {
    _ = try await tool.call(arguments: ["expression": "2 ** 8"])
  }
}

@Test func fileReadToolReadsAllowedFile() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("KarmaKitToolsTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let fileURL = directory.appendingPathComponent("note.txt")
  try "hello local agent".write(to: fileURL, atomically: true, encoding: .utf8)

  let tool = FileReadTool(allowedDirectories: [directory])
  let output = try await tool.call(arguments: ["path": fileURL.path])

  #expect(output == "hello local agent")
}

@Test func fileReadToolRejectsPathOutsideAllowedDirectories() async throws {
  let allowedDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("KarmaKitToolsTests-allowed-\(UUID().uuidString)")
  let outsideDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("KarmaKitToolsTests-outside-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: allowedDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
  let fileURL = outsideDirectory.appendingPathComponent("secret.txt")
  try "secret".write(to: fileURL, atomically: true, encoding: .utf8)

  let tool = FileReadTool(allowedDirectories: [allowedDirectory])

  await #expect(throws: KarmaToolError.pathNotAllowed(fileURL.standardizedFileURL.resolvingSymlinksInPath().path)) {
    _ = try await tool.call(arguments: ["path": fileURL.path])
  }
}

@Test func fileReadToolRejectsLargeFiles() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("KarmaKitToolsTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let fileURL = directory.appendingPathComponent("large.txt")
  try "abcdef".write(to: fileURL, atomically: true, encoding: .utf8)

  let tool = FileReadTool(allowedDirectories: [directory], maximumBytes: 3)

  await #expect(throws: KarmaToolError.fileTooLarge(path: fileURL.standardizedFileURL.resolvingSymlinksInPath().path, maximumBytes: 3)) {
    _ = try await tool.call(arguments: ["path": fileURL.path])
  }
}

@Test func agentCanUseMathToolThroughToolLoop() async throws {
  let model = ScriptedModel(outputs: [
    .toolCalls([
      ToolCall(name: "calculate", arguments: ["expression": "6 * 7"])
    ]),
    .finalAnswer("42")
  ])
  let agent = ToolCallingAgent(tools: [MathTool()], model: model)
  let run = try await agent.run("Calculate 6 times 7")

  #expect(run.steps.first?.toolResults.first?.output == "42")
  #expect(run.finalAnswer == "42")
}

@Test func searchFilesToolFindsMatchingLinesAsJSON() async throws {
  let directory = try makeTemporaryDirectory()
  let fileURL = directory.appendingPathComponent("notes.md")
  try """
  KarmaKit builds local agents.
  Foundation Models can use tools.
  Local agents need memory.
  """.write(to: fileURL, atomically: true, encoding: .utf8)

  let tool = SearchFilesTool(allowedDirectories: [directory])
  let output = try await tool.call(arguments: ["query": "agents"])
  let results = try JSONDecoder().decode([SearchResult].self, from: Data(output.utf8))

  #expect(results.count == 2)
  #expect(results.first?.path.hasSuffix("/\(fileURL.lastPathComponent)") == true)
  #expect(results.first?.line == 1)
  #expect(results.first?.excerpt == "KarmaKit builds local agents.")
}

@Test func searchFilesToolRespectsMaximumResults() async throws {
  let directory = try makeTemporaryDirectory()
  let fileURL = directory.appendingPathComponent("notes.txt")
  try """
  agent one
  agent two
  agent three
  """.write(to: fileURL, atomically: true, encoding: .utf8)

  let tool = SearchFilesTool(allowedDirectories: [directory], defaultMaximumResults: 10)
  let output = try await tool.call(arguments: ["query": "agent", "max_results": "2"])
  let results = try JSONDecoder().decode([SearchResult].self, from: Data(output.utf8))

  #expect(results.count == 2)
}

@Test func searchFilesToolSkipsUnsupportedExtensions() async throws {
  let directory = try makeTemporaryDirectory()
  try "agent".write(to: directory.appendingPathComponent("image.bin"), atomically: true, encoding: .utf8)

  let tool = SearchFilesTool(allowedDirectories: [directory], allowedExtensions: ["md"])
  let output = try await tool.call(arguments: ["query": "agent"])
  let results = try JSONDecoder().decode([SearchResult].self, from: Data(output.utf8))

  #expect(results.isEmpty)
}

@Test func searchFilesToolSkipsLargeFiles() async throws {
  let directory = try makeTemporaryDirectory()
  try "agent agent".write(to: directory.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)

  let tool = SearchFilesTool(allowedDirectories: [directory], maximumFileBytes: 3)
  let output = try await tool.call(arguments: ["query": "agent"])
  let results = try JSONDecoder().decode([SearchResult].self, from: Data(output.utf8))

  #expect(results.isEmpty)
}

@Test func searchFilesToolRejectsShortQueries() async throws {
  let tool = SearchFilesTool(allowedDirectories: [try makeTemporaryDirectory()])

  await #expect(throws: KarmaToolError.queryTooShort) {
    _ = try await tool.call(arguments: ["query": "a"])
  }
}

@Test func agentCanUseSearchFilesToolThroughToolLoop() async throws {
  let directory = try makeTemporaryDirectory()
  let fileURL = directory.appendingPathComponent("context.md")
  try "KarmaKit has local search.".write(to: fileURL, atomically: true, encoding: .utf8)
  let searchTool = SearchFilesTool(allowedDirectories: [directory])
  let model = ScriptedModel(outputs: [
    .toolCalls([
      ToolCall(name: "search_files", arguments: ["query": "local search"])
    ]),
    .finalAnswer("Found local search context.")
  ])
  let agent = ToolCallingAgent(tools: [searchTool], model: model)
  let run = try await agent.run("Find local search")

  #expect(run.steps.first?.toolResults.first?.output.contains("KarmaKit has local search.") == true)
  #expect(run.finalAnswer == "Found local search context.")
}

private func makeTemporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("KarmaKitToolsTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
