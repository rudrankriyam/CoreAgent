import CryptoKit
import Foundation
import FoundationModels

/// A production harness around one persistent native `LanguageModelSession`.
///
/// CoreAgent deliberately accepts Foundation Models types directly. It does not
/// define another provider, message, tool, schema, or agent-loop abstraction.
public actor CoreAgentSession {
  private typealias SessionFactory = (Transcript?) -> LanguageModelSession

  private let makeSession: SessionFactory
  private let configuration: CoreAgentConfiguration
  private let checkpointStore: (any CoreAgentCheckpointStore)?
  private let checkpointKey: String
  private let retention: CoreAgentTranscriptRetention
  private let requiresMatchingCheckpointConfiguration: Bool
  private let checkpointCompatibilityRevision: String
  private let recordsProfileToolLifecycle: Bool
  private let sessionMode: CoreAgentSessionMode
  private let plugins: [any CoreAgentSessionPlugin]
  private let toolRuntime: CoreAgentToolRuntime
  private let recorder: CoreAgentEventRecorder

  private var nativeSession: LanguageModelSession?
  private var mostRecentRun: CoreAgentRun?
  private var hasActiveOperation = false

  public init<Model: LanguageModel>(
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: CoreAgentInstructionRestorationPolicy = .replaceWithCurrent,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: toolConfiguration.maximumCallsPerRun)
    let allTools = tools + plugins.flatMap(\.tools)
    try Self.validateUniqueToolNames(allTools)
    let prepared = try allTools.map { tool -> (any Tool, CoreAgentToolManifest) in
      let manifest = try CoreAgentToolManifest(tool: tool)
      let erased = CoreAgentAnyTool(tool)
      let governed = CoreAgentGovernedTool(
        base: erased,
        manifest: manifest,
        configuration: toolConfiguration,
        runtime: runtime,
        recorder: recorder
      )
      return (governed, manifest)
    }
    let governedTools = prepared.map(\.0)
    let revision = Self.makeToolsetRevision(prepared.map(\.1))

    let makeSession: SessionFactory = { transcript in
      if let transcript {
        if case .replaceWithCurrent = instructionRestorationPolicy,
          instructions != nil
        {
          let current = LanguageModelSession(
            model: model,
            tools: governedTools,
            instructions: instructions
          )
          var rebased = current.transcript
          rebased.history = transcript.history
          return LanguageModelSession(model: model, tools: governedTools, transcript: rebased)
        }
        return LanguageModelSession(model: model, tools: governedTools, transcript: transcript)
      }
      return LanguageModelSession(model: model, tools: governedTools, instructions: instructions)
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: requiresMatchingToolset,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: false,
      sessionMode: .explicitModel,
      plugins: plugins,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  /// Creates a harness around a native Xcode 27 dynamic profile.
  ///
  /// The factory is called again for lazy checkpoint restoration and `reset()`.
  /// Profile-owned tools remain native and are not wrapped by CoreAgent policy.
  public init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    configuration: CoreAgentConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    profile makeProfile: @escaping @Sendable () -> sending Profile
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: .default,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)
    guard !checkpointCompatibilityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentError.emptyCheckpointCompatibilityID
    }
    if configuration.retryPolicy.maximumAttempts > 1 {
      throw CoreAgentError.unsafeRetryConfiguration(
        "Dynamic profiles may preserve partial history or own tools and lifecycle hooks that CoreAgent cannot intercept. Profile mode supports one attempt."
      )
    }

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: nil)
    let revision = Self.makeProfileRevision(checkpointCompatibilityID)
    let makeSession: SessionFactory = { transcript in
      let profile = makeProfile()
        .onToolCall { call in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolCallRecorded,
            message: "Native dynamic profile emitted a tool call.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
        .onToolOutput { call, _ in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolOutputRecorded,
            message: "Native dynamic profile emitted tool output.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
      return LanguageModelSession(
        profile: profile,
        history: transcript?.history ?? []
      )
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: true,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: true,
      sessionMode: .dynamicProfile,
      plugins: plugins,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  private init(
    makeSession: @escaping SessionFactory,
    configuration: CoreAgentConfiguration,
    checkpointStore: (any CoreAgentCheckpointStore)?,
    checkpointKey: String,
    transcriptRetention: CoreAgentTranscriptRetention,
    requiresMatchingCheckpointConfiguration: Bool,
    checkpointCompatibilityRevision: String,
    recordsProfileToolLifecycle: Bool,
    sessionMode: CoreAgentSessionMode,
    plugins: [any CoreAgentSessionPlugin],
    toolRuntime: CoreAgentToolRuntime,
    recorder: CoreAgentEventRecorder
  ) {
    self.makeSession = makeSession
    self.configuration = configuration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.retention = transcriptRetention
    self.requiresMatchingCheckpointConfiguration = requiresMatchingCheckpointConfiguration
    self.checkpointCompatibilityRevision = checkpointCompatibilityRevision
    self.recordsProfileToolLifecycle = recordsProfileToolLifecycle
    self.sessionMode = sessionMode
    self.plugins = plugins
    self.toolRuntime = toolRuntime
    self.recorder = recorder
  }

  public func prewarm(promptPrefix: Prompt? = nil) async throws {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    session.prewarm(promptPrefix: promptPrefix)
  }

  public func transcript() async throws -> Transcript {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    return try await resolveSession().transcript
  }

  public func lastRun() -> CoreAgentRun? {
    mostRecentRun
  }

  /// Waits up to `timeout` for previously emitted events to reach observers.
  /// Reports timeouts, reentrant calls, and any cumulative queue overflow.
  @discardableResult
  public func flushObservers(timeout: Duration? = nil) async -> CoreAgentObserverFlushResult {
    await recorder.flushObservers(timeout: timeout)
  }

  @discardableResult
  public func checkpoint() async throws -> CoreAgentCheckpoint {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    return try await persist(transcript: session.transcript, runID: nil)
  }

  public func reset(removingCheckpoint: Bool = false) async throws {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    nativeSession = makeSession(nil)
    nativeSession?.transcriptErrorHandlingPolicy =
      configuration.transcriptErrorHandlingPolicy.nativeValue
    mostRecentRun = nil
    if removingCheckpoint {
      try await checkpointStore?.removeCheckpoint(for: checkpointKey)
    }
  }

  @discardableResult
  public func respond(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<String> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond(
    to prompt: String,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<String> {
    try await respond(
      to: Prompt(prompt),
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respond<Content: Generable & Sendable>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<Content> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond<Content: Generable & Sendable>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<Content> {
    try await respond(
      to: Prompt(prompt),
      generating: type,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respond(
    to prompt: Prompt,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<GeneratedContent> {
    try await performResponse(prompt: prompt, contextQuery: contextQuery, metadata: metadata) {
      try await $0.respond(
        to: $1,
        schema: schema,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    }
  }

  @discardableResult
  public func respond(
    to prompt: String,
    schema: GenerationSchema,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil
  ) async throws -> CoreAgentResponse<GeneratedContent> {
    try await respond(
      to: Prompt(prompt),
      schema: schema,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt
    )
  }

  @discardableResult
  public func respondStreaming(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> CoreAgentResponse<String> {
    try await performStream(
      prompt: prompt,
      contextQuery: contextQuery,
      metadata: metadata
    ) { session, preparedPrompt in
      session.streamResponse(
        to: preparedPrompt,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    } onPartialResponse: { content, _ in
      await onPartialResponse(content)
    }
  }

  @discardableResult
  public func respondStreaming(
    to prompt: String,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (String) async -> Void
  ) async throws -> CoreAgentResponse<String> {
    try await respondStreaming(
      to: Prompt(prompt),
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt,
      onPartialResponse: onPartialResponse
    )
  }

  @discardableResult
  public func respondStreaming<Content: Generable & Sendable>(
    to prompt: Prompt,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try await performStream(
      prompt: prompt,
      contextQuery: contextQuery,
      metadata: metadata
    ) { session, preparedPrompt in
      session.streamResponse(
        to: preparedPrompt,
        generating: type,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
    } onPartialResponse: { content, _ in
      await onPartialResponse(content)
    }
  }

  @discardableResult
  public func respondStreaming<Content: Generable & Sendable>(
    to prompt: String,
    generating type: Content.Type = Content.self,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(includeSchemaInPrompt: true),
    metadata: CoreAgentRequestMetadata = [:],
    contextQuery: String? = nil,
    onPartialResponse: @escaping @Sendable (Content.PartiallyGenerated) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try await respondStreaming(
      to: Prompt(prompt),
      generating: type,
      options: options,
      contextOptions: contextOptions,
      metadata: metadata,
      contextQuery: contextQuery ?? prompt,
      onPartialResponse: onPartialResponse
    )
  }

  private func resolveSession() async throws -> LanguageModelSession {
    if let nativeSession {
      return nativeSession
    }

    let checkpoint = try await checkpointStore?.loadCheckpoint(for: checkpointKey)
    let transcript: Transcript?
    if let checkpoint {
      guard checkpoint.formatVersion == CoreAgentCheckpoint.currentFormatVersion else {
        throw CoreAgentError.unsupportedCheckpointVersion(checkpoint.formatVersion)
      }
      if requiresMatchingCheckpointConfiguration,
        checkpoint.compatibilityRevision != checkpointCompatibilityRevision
      {
        throw CoreAgentError.checkpointCompatibilityMismatch(
          expected: checkpointCompatibilityRevision,
          actual: checkpoint.compatibilityRevision
        )
      }
      transcript = checkpoint.transcript
    } else {
      transcript = nil
    }

    let session = makeSession(transcript)
    session.transcriptErrorHandlingPolicy = configuration.transcriptErrorHandlingPolicy.nativeValue
    nativeSession = session
    return session
  }

  private func performResponse<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    _ operation:
      @escaping @Sendable (LanguageModelSession, Prompt) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> CoreAgentResponse<Content> {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    let transcriptBeforeRun = session.transcript
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models run started.")
    await recordProfileAuditBoundary(runID: runID)
    await toolRuntime.begin(runID: runID)
    var completedModelResponse = false
    var pluginContext = PreparedPluginContext.empty

    do {
      pluginContext = try await preparePlugins(
        runID: runID,
        prompt: prompt,
        contextQuery: contextQuery,
        metadata: metadata
      )
      let preparedPrompt = makePrompt(prompt, contextBlocks: pluginContext.contextBlocks)
      let nativeResponse = try await responseWithRetry(
        session: session,
        runID: runID,
        operation: { try await operation($0, preparedPrompt) }
      )
      completedModelResponse = true
      let usage = CoreAgentUsage(nativeResponse.usage)
      let sanitizedTranscript = try await sanitizeCompletedTranscript(
        session.transcript,
        fallback: transcriptBeforeRun,
        context: pluginContext,
        runID: runID
      )
      let sanitizedEntries = try sanitizePluginContext(
        in: Array(nativeResponse.transcriptEntries),
        contextBlocks: pluginContext.contextBlocks,
        requiresMatch: false
      )
      installSession(transcript: sanitizedTranscript, ifNeededFor: pluginContext)
      if !recordsProfileToolLifecycle {
        await recordNativeToolEntries(nativeResponse.transcriptEntries, runID: runID)
      }
      await recorder.record(
        runID: runID,
        kind: .modelResponseCompleted,
        message: "Native model response completed.",
        attributes: [
          "input_tokens": String(usage.inputTokens),
          "output_tokens": String(usage.outputTokens),
          "transcript_entries": String(nativeResponse.transcriptEntries.count),
        ]
      )
      try await persistAfterSuccessfulResponse(transcript: sanitizedTranscript, runID: runID)
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: nativeResponse.rawContent,
          transcriptEntries: sanitizedEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await toolRuntime.finish(runID: runID)
      return CoreAgentResponse(
        content: nativeResponse.content,
        rawContent: nativeResponse.rawContent,
        transcriptEntries: Array(nativeResponse.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        CoreAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID,
        kind: .runFailed,
        message: String(describing: error),
        attributes: ["error_type": String(reflecting: Swift.type(of: error))]
      )
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
  }

  private func responseWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    operation:
      @escaping @Sendable (LanguageModelSession) async throws ->
      LanguageModelSession.Response<Content>
  ) async throws -> LanguageModelSession.Response<Content> {
    let retryPolicy = configuration.retryPolicy
    for attempt in 1...retryPolicy.maximumAttempts {
      await recorder.record(
        runID: runID,
        kind: .modelAttemptStarted,
        message: "Native model attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      do {
        guard let timeout = configuration.responseTimeout else {
          return try await operation(session)
        }
        do {
          let box = try await withCoreAgentTimeout(timeout) {
            NativeResponseBox(try await operation(session))
          }
          return box.response
        } catch is CoreAgentTimeoutMarker {
          throw CoreAgentError.responseTimedOut
        }
      } catch {
        await recorder.record(
          runID: runID,
          kind: .modelAttemptFailed,
          message: String(describing: error),
          attributes: [
            "attempt": String(attempt),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        let startedToolInvocation = await toolRuntime.hasStartedToolInvocation(runID: runID)
        let mayRetryAfterTools =
          !startedToolInvocation || configuration.allowsRetryAfterToolInvocation
        guard attempt < retryPolicy.maximumAttempts,
          mayRetryAfterTools,
          retryPolicy.shouldRetry(error)
        else {
          throw error
        }
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }

  private func performStream<Content: Generable & Sendable>(
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    _ makeStream:
      @escaping @Sendable (LanguageModelSession, Prompt) ->
      LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> CoreAgentResponse<Content> where Content.PartiallyGenerated: Sendable {
    try acquireSessionLease()
    defer { releaseSessionLease() }
    let session = try await resolveSession()
    let transcriptBeforeRun = session.transcript
    let runID = UUID()
    let startedAt = Date()
    await recorder.begin(runID: runID, message: "Foundation Models streaming run started.")
    await recordProfileAuditBoundary(runID: runID)
    await toolRuntime.begin(runID: runID)

    var completedModelResponse = false
    var pluginContext = PreparedPluginContext.empty
    do {
      pluginContext = try await preparePlugins(
        runID: runID,
        prompt: prompt,
        contextQuery: contextQuery,
        metadata: metadata
      )
      let preparedPrompt = makePrompt(prompt, contextBlocks: pluginContext.contextBlocks)
      let lastSnapshot = try await streamWithRetry(
        session: session,
        runID: runID,
        makeStream: { makeStream($0, preparedPrompt) },
        onPartialResponse: onPartialResponse
      )
      completedModelResponse = true
      let content = try Content(lastSnapshot.rawContent)
      let usage = CoreAgentUsage(lastSnapshot.usage)
      let sanitizedTranscript = try await sanitizeCompletedTranscript(
        session.transcript,
        fallback: transcriptBeforeRun,
        context: pluginContext,
        runID: runID
      )
      let sanitizedEntries = try sanitizePluginContext(
        in: Array(lastSnapshot.transcriptEntries),
        contextBlocks: pluginContext.contextBlocks,
        requiresMatch: false
      )
      installSession(transcript: sanitizedTranscript, ifNeededFor: pluginContext)
      if !recordsProfileToolLifecycle {
        await recordNativeToolEntries(lastSnapshot.transcriptEntries, runID: runID)
      }
      await recorder.record(
        runID: runID,
        kind: .modelResponseCompleted,
        message: "Native model stream completed.",
        attributes: [
          "input_tokens": String(usage.inputTokens),
          "output_tokens": String(usage.outputTokens),
          "transcript_entries": String(lastSnapshot.transcriptEntries.count),
        ]
      )
      try await persistAfterSuccessfulResponse(transcript: sanitizedTranscript, runID: runID)
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: lastSnapshot.rawContent,
          transcriptEntries: sanitizedEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await toolRuntime.finish(runID: runID)
      return CoreAgentResponse(
        content: content,
        rawContent: lastSnapshot.rawContent,
        transcriptEntries: Array(lastSnapshot.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        CoreAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await recorder.record(
        runID: runID,
        kind: .runFailed,
        message: String(describing: error),
        attributes: ["error_type": String(reflecting: Swift.type(of: error))]
      )
      _ = await finishRun(runID: runID, startedAt: startedAt, usage: nil)
      await toolRuntime.finish(runID: runID)
      throw error
    }
  }

  private func streamWithRetry<Content: Generable & Sendable>(
    session: LanguageModelSession,
    runID: UUID,
    makeStream:
      @escaping @Sendable (LanguageModelSession) -> LanguageModelSession.ResponseStream<Content>,
    onPartialResponse:
      @escaping @Sendable (Content.PartiallyGenerated, GeneratedContent) async -> Void
  ) async throws -> LanguageModelSession.ResponseStream<Content>.Snapshot
  where Content.PartiallyGenerated: Sendable {
    let retryPolicy = configuration.retryPolicy
    for attempt in 1...retryPolicy.maximumAttempts {
      await recorder.record(
        runID: runID,
        kind: .modelAttemptStarted,
        message: "Native model stream attempt started.",
        attributes: ["attempt": String(attempt)]
      )
      let state = StreamAttemptState()
      do {
        let consume: @Sendable () async throws -> NativeStreamSnapshotBox<Content> = {
          let stream = makeStream(session)
          var lastSnapshot: LanguageModelSession.ResponseStream<Content>.Snapshot?
          for try await snapshot in stream {
            try Task.checkCancellation()
            await state.markSnapshotEmitted()
            lastSnapshot = snapshot
            await onPartialResponse(snapshot.content, snapshot.rawContent)
          }
          guard let lastSnapshot else {
            throw CoreAgentError.streamFinishedWithoutResponse
          }
          return NativeStreamSnapshotBox(lastSnapshot)
        }

        guard let timeout = configuration.responseTimeout else {
          return try await consume().snapshot
        }
        do {
          return try await withCoreAgentTimeout(timeout, operation: consume).snapshot
        } catch is CoreAgentTimeoutMarker {
          throw CoreAgentError.responseTimedOut
        }
      } catch {
        let emittedSnapshot = await state.emittedSnapshot
        let startedToolInvocation = await toolRuntime.hasStartedToolInvocation(runID: runID)
        await recorder.record(
          runID: runID,
          kind: .modelAttemptFailed,
          message: String(describing: error),
          attributes: [
            "attempt": String(attempt),
            "emitted_partial_response": String(emittedSnapshot),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        let mayRetryAfterTools =
          !startedToolInvocation || configuration.allowsRetryAfterToolInvocation
        guard attempt < retryPolicy.maximumAttempts,
          !emittedSnapshot,
          mayRetryAfterTools,
          retryPolicy.shouldRetry(error)
        else {
          throw error
        }
        if retryPolicy.delay > .zero {
          try await Task.sleep(for: retryPolicy.delay)
        }
      }
    }
    preconditionFailure("Retry policy must execute at least once.")
  }

  private func preparePlugins(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata
  ) async throws -> PreparedPluginContext {
    var blocks: [CoreAgentContextBlock] = []
    var sanitizationFailurePolicy = CoreAgentPluginFailurePolicy.recordAndContinue

    for plugin in plugins {
      await recorder.record(
        runID: runID,
        kind: .pluginPreparationStarted,
        message: "CoreAgent session plugin preparation started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let preparation = try await plugin.prepare(
          for: CoreAgentPluginRequest(
            runID: runID,
            prompt: prompt,
            contextQuery: contextQuery,
            metadata: metadata,
            mode: sessionMode
          )
        )
        if sessionMode == .dynamicProfile, !preparation.contextBlocks.isEmpty {
          throw CoreAgentError.pluginContextUnsupportedForDynamicProfile
        }
        blocks.append(contentsOf: preparation.contextBlocks)
        if !preparation.contextBlocks.isEmpty,
          case .failRun = plugin.failurePolicies.sanitization
        {
          sanitizationFailurePolicy = .failRun
        }
        for block in preparation.contextBlocks {
          await recorder.record(
            runID: runID,
            kind: .pluginEvent,
            message: "CoreAgent session plugin contributed context.",
            attributes: [
              "plugin": plugin.identifier,
              "plugin_event": "context_prepared",
              "context_block_id": block.id,
            ].merging(block.attributes) { current, _ in current }
          )
        }
        await recordPluginEvents(preparation.events, plugin: plugin.identifier, runID: runID)
        await recorder.record(
          runID: runID,
          kind: .pluginPreparationCompleted,
          message: "CoreAgent session plugin preparation completed.",
          attributes: [
            "plugin": plugin.identifier,
            "context_blocks": String(preparation.contextBlocks.count),
          ]
        )
      } catch {
        await recorder.record(
          runID: runID,
          kind: .pluginPreparationFailed,
          message: String(describing: error),
          attributes: [
            "plugin": plugin.identifier,
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        if case .failRun = plugin.failurePolicies.preparation {
          throw error
        }
      }
    }

    return PreparedPluginContext(
      contextBlocks: blocks,
      sanitizationFailurePolicy: sanitizationFailurePolicy
    )
  }

  private func completePlugins(_ completion: CoreAgentPluginCompletion) async throws {
    var fatalError: (any Error)?

    for plugin in plugins {
      await recorder.record(
        runID: completion.runID,
        kind: .pluginCompletionStarted,
        message: "CoreAgent session plugin completion started.",
        attributes: ["plugin": plugin.identifier]
      )
      do {
        let events = try await plugin.didComplete(completion)
        await recordPluginEvents(events, plugin: plugin.identifier, runID: completion.runID)
        await recorder.record(
          runID: completion.runID,
          kind: .pluginCompletionCompleted,
          message: "CoreAgent session plugin completion completed.",
          attributes: ["plugin": plugin.identifier]
        )
      } catch {
        await recorder.record(
          runID: completion.runID,
          kind: .pluginCompletionFailed,
          message: String(describing: error),
          attributes: [
            "plugin": plugin.identifier,
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
        if case .failRun = plugin.failurePolicies.completion, fatalError == nil {
          fatalError = error
        }
      }
    }

    if let fatalError {
      throw fatalError
    }
  }

  private func failPlugins(_ failure: CoreAgentPluginFailure) async {
    for plugin in plugins {
      let events = await plugin.didFail(failure)
      await recordPluginEvents(events, plugin: plugin.identifier, runID: failure.runID)
    }
  }

  private func recordPluginEvents(
    _ events: [CoreAgentPluginEvent],
    plugin: String,
    runID: UUID
  ) async {
    for event in events {
      var attributes = event.attributes
      attributes["plugin"] = plugin
      attributes["plugin_event"] = event.name
      await recorder.record(
        runID: runID,
        kind: .pluginEvent,
        message: event.message,
        attributes: attributes
      )
    }
  }

  private func makePrompt(
    _ prompt: Prompt,
    contextBlocks: [CoreAgentContextBlock]
  ) -> Prompt {
    guard !contextBlocks.isEmpty else { return prompt }
    return Prompt {
      contextBlocks.map(\.content)
      prompt
    }
  }

  private func sanitizePluginContext(
    in transcript: Transcript,
    contextBlocks: [CoreAgentContextBlock],
    requiresMatch: Bool
  ) throws -> Transcript {
    let sanitized = try sanitizePluginContext(
      in: Array(transcript),
      contextBlocks: contextBlocks,
      requiresMatch: requiresMatch
    )
    var transcript = Transcript()
    transcript.append(contentsOf: sanitized)
    return transcript
  }

  private func sanitizePluginContext(
    in entries: [Transcript.Entry],
    contextBlocks: [CoreAgentContextBlock],
    requiresMatch: Bool
  ) throws -> [Transcript.Entry] {
    guard !contextBlocks.isEmpty else { return entries }
    let expected = contextBlocks.map(\.content)
    var entries = entries

    for index in entries.indices.reversed() {
      guard case .prompt(let prompt) = entries[index],
        prompt.segments.count >= expected.count
      else {
        continue
      }
      let prefix = prompt.segments.prefix(expected.count)
      let matches = zip(prefix, expected).allSatisfy { segment, content in
        guard case .text(let text) = segment else { return false }
        return text.content == content
      }
      guard matches else { continue }

      let sanitizedPrompt = Transcript.Prompt(
        id: prompt.id,
        metadata: prompt.metadata,
        segments: Array(prompt.segments.dropFirst(expected.count)),
        options: prompt.options,
        responseFormat: prompt.responseFormat,
        contextOptions: prompt.contextOptions
      )
      entries[index] = .prompt(sanitizedPrompt)
      return entries
    }

    if requiresMatch {
      throw CoreAgentError.pluginContextSanitizationFailed
    }
    return entries
  }

  private func sanitizeCompletedTranscript(
    _ transcript: Transcript,
    fallback: Transcript,
    context: PreparedPluginContext,
    runID: UUID
  ) async throws -> Transcript {
    do {
      return try sanitizePluginContext(
        in: transcript,
        contextBlocks: context.contextBlocks,
        requiresMatch: !context.contextBlocks.isEmpty
      )
    } catch {
      await recordSanitizationFailure(error, context: context, runID: runID)
      if case .failRun = context.sanitizationFailurePolicy {
        throw error
      }
      return fallback
    }
  }

  private func sanitizeFailedTranscript(
    _ transcript: Transcript,
    fallback: Transcript,
    context: PreparedPluginContext,
    runID: UUID
  ) async -> Transcript {
    do {
      return try sanitizePluginContext(
        in: transcript,
        contextBlocks: context.contextBlocks,
        requiresMatch: !context.contextBlocks.isEmpty
      )
    } catch {
      await recordSanitizationFailure(error, context: context, runID: runID)
      return fallback
    }
  }

  private func recordSanitizationFailure(
    _ error: any Error,
    context: PreparedPluginContext,
    runID: UUID
  ) async {
    await recorder.record(
      runID: runID,
      kind: .pluginEvent,
      message: "CoreAgent could not verify injected context during transcript sanitization.",
      attributes: [
        "plugin_event": "context_sanitization_failed",
        "context_block_ids": context.contextBlocks.map(\.id).joined(separator: ","),
        "error_type": String(reflecting: Swift.type(of: error)),
        "history_reverted": "true",
      ]
    )
  }

  private func installSession(
    transcript: Transcript,
    ifNeededFor context: PreparedPluginContext
  ) {
    guard sessionMode == .explicitModel, !context.contextBlocks.isEmpty else { return }
    let session = makeSession(transcript)
    session.transcriptErrorHandlingPolicy = configuration.transcriptErrorHandlingPolicy.nativeValue
    nativeSession = session
  }

  private func persist(transcript: Transcript, runID: UUID?) async throws -> CoreAgentCheckpoint {
    let retained = try await retention.prepareForPersistence(transcript)
    let checkpoint = CoreAgentCheckpoint(
      compatibilityRevision: checkpointCompatibilityRevision,
      transcript: retained
    )
    try await checkpointStore?.saveCheckpoint(checkpoint, for: checkpointKey)
    if let runID, checkpointStore != nil {
      await recorder.record(
        runID: runID,
        kind: .transcriptCheckpointed,
        message: "Native transcript checkpointed.",
        attributes: ["history_entries": String(retained.history.count)]
      )
    }
    return checkpoint
  }

  private func persistAfterSuccessfulResponse(
    transcript: Transcript,
    runID: UUID
  ) async throws {
    guard checkpointStore != nil else { return }
    do {
      _ = try await persist(transcript: transcript, runID: runID)
    } catch {
      await recordCheckpointFailure(error, runID: runID)
      if case .failRun = configuration.checkpointFailurePolicy {
        throw error
      }
    }
  }

  private func persistAfterFailedResponse(
    transcript: Transcript,
    runID: UUID
  ) async {
    guard checkpointStore != nil else { return }
    do {
      _ = try await persist(transcript: transcript, runID: runID)
    } catch {
      await recordCheckpointFailure(error, runID: runID)
    }
  }

  private func recordCheckpointFailure(_ error: any Error, runID: UUID) async {
    await recorder.record(
      runID: runID,
      kind: .transcriptCheckpointFailed,
      message: String(describing: error),
      attributes: ["error_type": String(reflecting: Swift.type(of: error))]
    )
  }

  private func recordNativeToolEntries(
    _ entries: ArraySlice<Transcript.Entry>,
    runID: UUID
  ) async {
    for entry in entries {
      switch entry {
      case .toolCalls(let calls):
        for call in calls {
          await recorder.record(
            runID: runID,
            kind: .nativeToolCallRecorded,
            message: "Native transcript recorded a tool call.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
      case .toolOutput(let output):
        await recorder.record(
          runID: runID,
          kind: .nativeToolOutputRecorded,
          message: "Native transcript recorded tool output.",
          attributes: [
            "native_call_id": output.id,
            "tool": output.toolName,
          ]
        )
      default:
        continue
      }
    }
  }

  private func recordProfileAuditBoundary(runID: UUID) async {
    guard recordsProfileToolLifecycle else { return }
    await recorder.record(
      runID: runID,
      kind: .profileToolAuditBestEffort,
      message:
        "Dynamic-profile tool observation is best effort; an earlier failing profile lifecycle hook can preempt CoreAgent observation."
    )
  }

  private func finishRun(
    runID: UUID,
    startedAt: Date,
    usage: CoreAgentUsage?
  ) async -> CoreAgentRun {
    let events = await recorder.events(for: runID)
    let run = CoreAgentRun(
      id: runID,
      startedAt: startedAt,
      endedAt: Date(),
      usage: usage,
      events: events
    )
    mostRecentRun = run
    await recorder.discard(runID: runID)
    return run
  }

  private func acquireSessionLease() throws {
    guard !hasActiveOperation else {
      throw CoreAgentError.concurrentOperation
    }
    hasActiveOperation = true
  }

  private func releaseSessionLease() {
    hasActiveOperation = false
  }

  private static func makeToolsetRevision(_ manifests: [CoreAgentToolManifest]) -> String {
    let source = manifests.sorted { $0.name < $1.name }.map(\.digest).joined(separator: "\n")
    return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func makeProfileRevision(_ compatibilityID: String) -> String {
    SHA256.hash(data: Data("coreagent-profile-v1\u{0}\(compatibilityID)".utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func validate(
    configuration: CoreAgentConfiguration,
    toolConfiguration: CoreAgentToolConfiguration,
    transcriptRetention: CoreAgentTranscriptRetention,
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration
  ) throws {
    if let timeout = configuration.responseTimeout, timeout < .zero {
      throw CoreAgentError.invalidDuration(name: "Response timeout")
    }
    if let timeout = toolConfiguration.executionTimeout, timeout < .zero {
      throw CoreAgentError.invalidDuration(name: "Tool execution timeout")
    }
    if let limit = toolConfiguration.maximumCallsPerRun, limit < 0 {
      throw CoreAgentError.invalidToolCallLimit(limit)
    }
    guard observerDeliveryConfiguration.maximumPendingEvents > 0 else {
      throw CoreAgentError.invalidObserverQueueLimit(
        observerDeliveryConfiguration.maximumPendingEvents)
    }
    guard observerDeliveryConfiguration.defaultFlushTimeout >= .zero else {
      throw CoreAgentError.invalidDuration(name: "Observer flush timeout")
    }
    if case .preserve = configuration.transcriptErrorHandlingPolicy,
      configuration.retryPolicy.maximumAttempts > 1
    {
      throw CoreAgentError.unsafeRetryConfiguration(
        "Preserved partial transcripts cannot be retried safely. Use .revert or one attempt."
      )
    }
    try transcriptRetention.validate()
  }

  private static func validate(plugins: [any CoreAgentSessionPlugin]) throws {
    var identifiers: Set<String> = []
    for plugin in plugins {
      let identifier = plugin.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty else {
        throw CoreAgentError.emptyPluginIdentifier
      }
      guard identifiers.insert(identifier).inserted else {
        throw CoreAgentError.duplicatePluginIdentifier(identifier)
      }
    }
  }

  private static func validateUniqueToolNames(_ tools: [any Tool]) throws {
    var names: Set<String> = []
    for tool in tools {
      guard names.insert(tool.name).inserted else {
        throw CoreAgentError.duplicateToolName(tool.name)
      }
    }
  }
}

private struct PreparedPluginContext: Sendable {
  let contextBlocks: [CoreAgentContextBlock]
  let sanitizationFailurePolicy: CoreAgentPluginFailurePolicy

  static let empty = PreparedPluginContext(
    contextBlocks: [],
    sanitizationFailurePolicy: .recordAndContinue
  )
}

private final class NativeResponseBox<Content: Generable>: @unchecked Sendable {
  let response: LanguageModelSession.Response<Content>

  init(_ response: LanguageModelSession.Response<Content>) {
    self.response = response
  }
}

private final class NativeStreamSnapshotBox<Content: Generable>: @unchecked Sendable {
  let snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot

  init(_ snapshot: LanguageModelSession.ResponseStream<Content>.Snapshot) {
    self.snapshot = snapshot
  }
}

private actor StreamAttemptState {
  private(set) var emittedSnapshot = false

  func markSnapshotEmitted() {
    emittedSnapshot = true
  }
}
