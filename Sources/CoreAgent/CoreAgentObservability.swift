import CryptoKit
import Foundation

public enum CoreAgentEventKind: String, Codable, Equatable, Sendable {
  case runStarted
  case modelAttemptStarted
  case modelAttemptFailed
  case modelResponseCompleted
  case profileToolAuditBestEffort
  case toolAuthorizationStarted
  case toolAuthorizationSucceeded
  case toolAuthorizationDenied
  case toolAuthorizationCancelled
  case toolAuthorizationFailed
  case toolExecutionStarted
  case toolExecutionCompleted
  case toolExecutionFailed
  case nativeToolCallRecorded
  case nativeToolOutputRecorded
  case transcriptCheckpointed
  case transcriptCheckpointFailed
  case runCompleted
  case runFailed
}

public struct CoreAgentEvent: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let runID: UUID
  public let timestamp: Date
  public let kind: CoreAgentEventKind
  public let message: String
  public let attributes: [String: String]

  public init(
    id: UUID = UUID(),
    runID: UUID,
    timestamp: Date = Date(),
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.runID = runID
    self.timestamp = timestamp
    self.kind = kind
    self.message = message
    self.attributes = attributes
  }
}

public protocol CoreAgentObserver: Sendable {
  func receive(_ event: CoreAgentEvent) async
}

public struct ClosureCoreAgentObserver: CoreAgentObserver {
  private let handler: @Sendable (CoreAgentEvent) async -> Void

  public init(_ handler: @escaping @Sendable (CoreAgentEvent) async -> Void) {
    self.handler = handler
  }

  public func receive(_ event: CoreAgentEvent) async {
    await handler(event)
  }
}

public enum CoreAgentObserverOverflowPolicy: Sendable {
  /// Preserve the newest events when an observer cannot keep up.
  case dropOldest
  /// Preserve the events already waiting for delivery.
  case dropNewest
}

public struct CoreAgentObserverDeliveryConfiguration: Sendable {
  public var maximumPendingEvents: Int
  public var overflowPolicy: CoreAgentObserverOverflowPolicy
  public var defaultFlushTimeout: Duration

  public init(
    maximumPendingEvents: Int = 256,
    overflowPolicy: CoreAgentObserverOverflowPolicy = .dropOldest,
    defaultFlushTimeout: Duration = .seconds(5)
  ) {
    self.maximumPendingEvents = maximumPendingEvents
    self.overflowPolicy = overflowPolicy
    self.defaultFlushTimeout = defaultFlushTimeout
  }

  public static let `default` = CoreAgentObserverDeliveryConfiguration()
}

public enum CoreAgentObserverFlushStatus: Sendable, Equatable {
  /// Every queued event covered by the flush barrier is now settled.
  case drained
  /// At least one observer did not settle its covered events before the deadline.
  case timedOut
  /// The task waiting for observer delivery was cancelled.
  case cancelled
  /// An observer tried to flush its own delivery queue.
  case reentrant
}

public struct CoreAgentObserverFlushResult: Sendable, Equatable {
  public let status: CoreAgentObserverFlushStatus
  /// Total events dropped by all observer queues since this session was created.
  public let cumulativeDroppedEventCount: Int

  public init(
    status: CoreAgentObserverFlushStatus,
    cumulativeDroppedEventCount: Int
  ) {
    self.status = status
    self.cumulativeDroppedEventCount = cumulativeDroppedEventCount
  }

  /// `true` only when the barrier drained and no observer event has ever been dropped.
  public var deliveredAllEvents: Bool {
    status == .drained && cumulativeDroppedEventCount == 0
  }
}

public struct CoreAgentRedactionPolicy: Sendable {
  private let redactor: @Sendable (String) -> String

  public init(_ redactor: @escaping @Sendable (String) -> String) {
    self.redactor = redactor
  }

  public func redact(_ value: String) -> String {
    redactor(value)
  }

  public static let none = CoreAgentRedactionPolicy { $0 }

  public static let standard = CoreAgentRedactionPolicy { value in
    var result = value
    let patterns: [(String, String)] = [
      (#"(?i)bearer\s+[a-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
      (#"(?i)\bsk-[a-z0-9_-]{8,}\b"#, "[REDACTED_API_KEY]"),
      (
        #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#,
        "$1=[REDACTED]"
      ),
    ]
    for (pattern, replacement) in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }
    return result
  }

  fileprivate func redact(attributes: [String: String]) -> [String: String] {
    let sensitiveMarkers = ["authorization", "api_key", "apikey", "token", "secret", "password"]
    return attributes.mapValues { redactor($0) }.reduce(into: [:]) { result, pair in
      if sensitiveMarkers.contains(where: { pair.key.lowercased().contains($0) }) {
        result[pair.key] = "[REDACTED]"
      } else {
        result[pair.key] = pair.value
      }
    }
  }
}

public struct CoreAgentRun: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let startedAt: Date
  public let endedAt: Date
  public let usage: CoreAgentUsage?
  public let events: [CoreAgentEvent]

  public init(
    id: UUID,
    startedAt: Date,
    endedAt: Date,
    usage: CoreAgentUsage?,
    events: [CoreAgentEvent]
  ) {
    self.id = id
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.usage = usage
    self.events = events
  }

  public var duration: TimeInterval {
    endedAt.timeIntervalSince(startedAt)
  }
}

public struct CoreAgentEventReceipt: Codable, Equatable, Sendable {
  public let index: Int
  public let previousHash: String?
  public let hash: String
  public let event: CoreAgentEvent

  public init(index: Int, previousHash: String?, hash: String, event: CoreAgentEvent) {
    self.index = index
    self.previousHash = previousHash
    self.hash = hash
    self.event = event
  }
}

public struct CoreAgentRunReceipt: Codable, Equatable, Sendable {
  public let runID: UUID
  public let receipts: [CoreAgentEventReceipt]
  public let rootHash: String?

  public init(runID: UUID, receipts: [CoreAgentEventReceipt], rootHash: String?) {
    self.runID = runID
    self.receipts = receipts
    self.rootHash = rootHash
  }

  public init(run: CoreAgentRun) throws {
    var previousHash: String? = Self.chainSeed(runID: run.id)
    var values: [CoreAgentEventReceipt] = []
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]

    for (index, event) in run.events.enumerated() {
      let payload = try Self.payload(
        index: index, previousHash: previousHash, event: event, encoder: encoder)
      let hash = Self.sha256(payload)
      values.append(.init(index: index, previousHash: previousHash, hash: hash, event: event))
      previousHash = hash
    }

    self.runID = run.id
    self.receipts = values
    self.rootHash = previousHash
  }

  public func verify() -> Bool {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    var previousHash: String? = Self.chainSeed(runID: runID)

    for (index, receipt) in receipts.enumerated() {
      guard receipt.index == index,
        receipt.event.runID == runID,
        receipt.previousHash == previousHash,
        let payload = try? Self.payload(
          index: index,
          previousHash: previousHash,
          event: receipt.event,
          encoder: encoder
        ),
        Self.sha256(payload) == receipt.hash
      else {
        return false
      }
      previousHash = receipt.hash
    }
    return previousHash == rootHash
  }

  private static func payload(
    index: Int,
    previousHash: String?,
    event: CoreAgentEvent,
    encoder: JSONEncoder
  ) throws -> Data {
    struct Payload: Codable {
      let index: Int
      let previousHash: String?
      let event: CoreAgentEvent
    }
    return try encoder.encode(Payload(index: index, previousHash: previousHash, event: event))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func chainSeed(runID: UUID) -> String {
    sha256(Data("coreagent-receipt-v1\u{0}\(runID.uuidString.lowercased())".utf8))
  }
}

public struct CoreAgentTraceExporter: Sendable {
  public init() {}

  public func data(for run: CoreAgentRun, prettyPrinted: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(run)
  }

  public func write(_ run: CoreAgentRun, to url: URL, prettyPrinted: Bool = true) throws {
    try data(for: run, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }
}

public struct CoreAgentReceiptExporter: Sendable {
  public init() {}

  public func data(for run: CoreAgentRun, prettyPrinted: Bool = true) throws -> Data {
    let receipt = try CoreAgentRunReceipt(run: run)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(receipt)
  }

  public func write(_ run: CoreAgentRun, to url: URL, prettyPrinted: Bool = true) throws {
    try data(for: run, prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
  }

  public func decode(_ data: Data) throws -> CoreAgentRunReceipt {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(CoreAgentRunReceipt.self, from: data)
  }

  public func decode(contentsOf url: URL) throws -> CoreAgentRunReceipt {
    try decode(Data(contentsOf: url))
  }
}

private enum CoreAgentObserverDeliveryContext {
  @TaskLocal static var isDelivering = false
}

private struct CoreAgentObserverBarrier: Sendable {
  let sequence: Int
}

private actor CoreAgentObserverDelivery {
  private struct PendingEvent {
    let sequence: Int
    let event: CoreAgentEvent
  }

  private let observer: any CoreAgentObserver
  private let configuration: CoreAgentObserverDeliveryConfiguration
  private var pending: [PendingEvent] = []
  private var isDelivering = false
  private var nextSequence = 0
  private var unsettledSequences: Set<Int> = []
  private var cumulativeDroppedEventCount = 0

  init(
    observer: any CoreAgentObserver,
    configuration: CoreAgentObserverDeliveryConfiguration
  ) {
    self.observer = observer
    self.configuration = configuration
  }

  func enqueue(_ event: CoreAgentEvent) {
    let item = PendingEvent(sequence: nextSequence, event: event)
    nextSequence += 1

    if pending.count >= configuration.maximumPendingEvents {
      switch configuration.overflowPolicy {
      case .dropOldest:
        let dropped = pending.removeFirst()
        unsettledSequences.remove(dropped.sequence)
        cumulativeDroppedEventCount += 1
      case .dropNewest:
        cumulativeDroppedEventCount += 1
        return
      }
    }

    pending.append(item)
    unsettledSequences.insert(item.sequence)
    guard !isDelivering else { return }
    isDelivering = true
    Task { await drain() }
  }

  func barrier() -> CoreAgentObserverBarrier {
    CoreAgentObserverBarrier(sequence: nextSequence - 1)
  }

  func hasSettled(through sequence: Int) -> Bool {
    !unsettledSequences.contains { $0 <= sequence }
  }

  func droppedEventCount() -> Int {
    cumulativeDroppedEventCount
  }

  private func drain() async {
    while !pending.isEmpty {
      let item = pending.removeFirst()
      await CoreAgentObserverDeliveryContext.$isDelivering.withValue(true) {
        await observer.receive(item.event)
      }
      unsettledSequences.remove(item.sequence)
    }
    isDelivering = false
  }
}

actor CoreAgentEventRecorder {
  private let deliveries: [CoreAgentObserverDelivery]
  private let deliveryConfiguration: CoreAgentObserverDeliveryConfiguration
  private let redactionPolicy: CoreAgentRedactionPolicy
  private var eventsByRun: [UUID: [CoreAgentEvent]] = [:]

  init(
    observers: [any CoreAgentObserver],
    redactionPolicy: CoreAgentRedactionPolicy,
    deliveryConfiguration: CoreAgentObserverDeliveryConfiguration
  ) {
    self.deliveries = observers.map {
      CoreAgentObserverDelivery(observer: $0, configuration: deliveryConfiguration)
    }
    self.deliveryConfiguration = deliveryConfiguration
    self.redactionPolicy = redactionPolicy
  }

  func begin(runID: UUID, message: String) async {
    eventsByRun[runID] = []
    await record(runID: runID, kind: .runStarted, message: message)
  }

  func record(
    runID: UUID,
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) async {
    let event = CoreAgentEvent(
      runID: runID,
      kind: kind,
      message: redactionPolicy.redact(message),
      attributes: redactionPolicy.redact(attributes: attributes)
    )
    eventsByRun[runID, default: []].append(event)
    for delivery in deliveries {
      await delivery.enqueue(event)
    }
  }

  func events(for runID: UUID) -> [CoreAgentEvent] {
    eventsByRun[runID] ?? []
  }

  func discard(runID: UUID) {
    eventsByRun.removeValue(forKey: runID)
  }

  func flushObservers(timeout: Duration? = nil) async -> CoreAgentObserverFlushResult {
    guard !CoreAgentObserverDeliveryContext.isDelivering else {
      return CoreAgentObserverFlushResult(
        status: .reentrant,
        cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
      )
    }

    var barriers: [(CoreAgentObserverDelivery, CoreAgentObserverBarrier)] = []
    for delivery in deliveries {
      barriers.append((delivery, await delivery.barrier()))
    }
    guard !barriers.isEmpty else {
      return CoreAgentObserverFlushResult(
        status: .drained,
        cumulativeDroppedEventCount: 0
      )
    }

    let duration = timeout ?? deliveryConfiguration.defaultFlushTimeout
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    while true {
      var complete = true
      for (delivery, barrier) in barriers
      where !(await delivery.hasSettled(through: barrier.sequence)) {
        complete = false
        break
      }
      if complete {
        return CoreAgentObserverFlushResult(
          status: .drained,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      if Task.isCancelled {
        return CoreAgentObserverFlushResult(
          status: .cancelled,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      if duration <= .zero || clock.now >= deadline {
        return CoreAgentObserverFlushResult(
          status: .timedOut,
          cumulativeDroppedEventCount: await cumulativeDroppedEventCount()
        )
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private func cumulativeDroppedEventCount() async -> Int {
    var count = 0
    for delivery in deliveries {
      count += await delivery.droppedEventCount()
    }
    return count
  }
}
