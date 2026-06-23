# CoreAgent

**Foundation Models makes any model callable. CoreAgent makes any model shippable.**

CoreAgent is a production harness for Apple's Foundation Models API. Give it any
type that conforms to `LanguageModel` and keep using native `Prompt`,
`Transcript`, `Tool`, `GeneratedContent`, and `Generable` values end to end.

CoreAgent adds the layer an app still needs around the native session:

- approval, allowlist, and trusted-manifest policy before tools execute;
- per-run tool budgets and cooperative tool/model timeouts;
- retries for failures your app classifies as safe;
- versioned, durable native-transcript checkpoints;
- optional scoped long-term memory with SQLite FTS, approval, and deletion;
- toolset validation when restoring a checkpoint;
- ordered run events, observers, usage, and tamper-evident receipts;
- deterministic, zero-network model fixtures for tests;
- optional first-party Apple, Anthropic, and Google provider packages.

CoreAgent does **not** define another provider protocol, message format, schema
tree, tool protocol, or agent loop. Foundation Models owns those primitives.

## Requirements

- Swift 6.4
- Xcode 27
- iOS 27+, macOS 27+, or visionOS 27+

Apple has announced that the Foundation Models core will become open source.
Until that source and its package manifest ship, CoreAgent makes no iOS 18 or
Linux compatibility claim.

## Installation

Add CoreAgent with Swift Package Manager:

```swift
dependencies: [
  .package(
    url: "https://github.com/rudrankriyam/CoreAgent.git",
    from: "0.2.0"
  )
]
```

Add the main library to your target:

```swift
.product(name: "CoreAgent", package: "CoreAgent")
```

Add `CoreAgentMemory` only when the app needs inspectable long-term memory:

```swift
.product(name: "CoreAgentMemory", package: "CoreAgent")
```

## Quick start

```swift
import CoreAgent
import FoundationModels

let agent = try CoreAgentSession(
  model: SystemLanguageModel.default,
  instructions: Instructions {
    "Be concise. Use a tool only when it materially improves the answer."
  }
)

let response = try await agent.respond(to: "Explain tool calling in one sentence.")
print(response.content)
print(response.usage)
```

The session is persistent. Foundation Models retains its native transcript and
CoreAgent returns the typed response, raw generated content, new transcript
entries, token usage, and audited run.

## Xcode 27 dynamic profiles

Use the profile-factory initializer when Foundation Models' dynamic profile is
the composition root. This preserves native dynamic instructions, model
switching, lifecycle hooks, and utilities such as Skills and history modifiers:

```swift
let agent = try CoreAgentSession(
  checkpointCompatibilityID: "assistant-profile-v1",
  checkpointStore: store,
  checkpointKey: "assistant:user-123"
) {
  LanguageModelSession.Profile {
    Instructions("Help the user with the current project.")
    dynamicTools
  }
  .model(model)
}
```

CoreAgent stores an `@Sendable` factory and calls it again for lazy restore and
`reset()`. Each returned profile is transferred to Foundation Models with
`sending`, so the factory may create fresh non-`Sendable` state; state shared
across profile instances must itself be `Sendable` (as Apple's
`SkillActivations` is). CoreAgent restores only `Transcript.history`, allowing
the current profile to rematerialize its instructions, tools, model, and
modifiers. Change
`checkpointCompatibilityID` whenever that contract changes. Dynamic state that
is not in a transcript—including `SkillActivations`, closures, and session
properties—must be persisted and reinjected by the app before the factory runs.
Profile history transforms run inside Foundation Models; CoreAgent's transcript
retention runs afterward at persistence time, so avoid configuring two
compactors that discard the same context.

Profile-owned tools are intentionally not advertised as governed: Foundation
Models keeps those tools opaque to CoreAgent's `AnyTool` wrappers. Use the
explicit `model:tools:instructions:` initializer when approval, call budgets,
trusted manifests, or per-tool execution timeouts are required. Profile mode
rejects multi-attempt retries because CoreAgent cannot safely observe
profile-owned tools, lifecycle hooks, or transcript-policy modifiers before
they take effect. CoreAgent attaches best-effort observation-only `onToolCall`
and `onToolOutput` modifiers. They preserve native call/output IDs when their
lifecycle chain completes, including when a later model continuation reverts
the transcript. An earlier throwing hook inside the supplied profile can
preempt CoreAgent's outer observer and erase that evidence; every profile run
contains `profileToolAuditBestEffort` to make this limit machine-visible.

## Native typed and multimodal input

There is no CoreAgent-specific message type to flatten rich input.

```swift
@Generable
struct Inspection: Sendable {
  let summary: String
  let severity: String
}

let prompt = Prompt {
  Attachment(image).label("screenshot")
  "Inspect this UI failure."
}

let response = try await agent.respond(
  to: prompt,
  generating: Inspection.self
)

print(response.content.summary)
```

Provider-defined `Transcript.CustomSegment` values can carry modalities such as
audio or video without CoreAgent needing to understand or convert them.

## Govern native tools

Pass ordinary Foundation Models tools. CoreAgent applies an internal type
eraser and policy, then delegates execution back to the native session.

```swift
@Generable
struct SendEmailArguments: Sendable {
  let recipient: String
  let subject: String
  let body: String
}

struct SendEmailTool: Tool {
  let name = "send_email"
  let description = "Send an email after explicit approval."

  @concurrent
  func call(arguments: SendEmailArguments) async throws -> String {
    // Perform the side effect.
    "sent"
  }
}

let approval = ClosureCoreAgentApprovalProvider { request in
  // request.arguments is native GeneratedContent.
  print(request.argumentsJSON)
  return await askUserToApprove(request) ? .approve : .deny(reason: "User declined")
}

let agent = try CoreAgentSession(
  model: SystemLanguageModel.default,
  tools: [SendEmailTool()],
  toolConfiguration: CoreAgentToolConfiguration(
    policy: CompositeCoreAgentToolPolicy([
      ToolNameAllowlistPolicy(["send_email"]),
      ApprovalRequiredToolPolicy(
        requiredNames: ["send_email"],
        provider: approval
      )
    ]),
    executionTimeout: .seconds(15),
    maximumCallsPerRun: 3
  )
)
```

`CoreAgentToolManifest` hashes the native tool name, description, and encoded
`GenerationSchema`. Persist approved digests and enforce them with
`TrustedToolManifestPolicy` to detect a changed tool contract.

## Durable native transcript checkpoints

CoreAgent checkpoints `Transcript` rather than inventing a lossy conversation
format.

```swift
let store = FileCheckpointStore(
  directory: URL.applicationSupportDirectory
    .appending(path: "CoreAgent", directoryHint: .isDirectory)
)

let agent = try CoreAgentSession(
  model: model,
  tools: tools,
  instructions: Instructions("Help the user."),
  checkpointStore: store,
  checkpointKey: "support-agent:user-123"
)

_ = try await agent.respond(to: prompt) // checkpoints after success
let checkpoint = try await agent.checkpoint()
```

On the next launch, the first request restores the checkpoint lazily. By
default, CoreAgent rejects it if the current tool manifests do not match the
saved toolset revision. Dynamic-profile sessions instead validate the required
`checkpointCompatibilityID` supplied by the app.

Use `CoreAgentTranscriptRetention.latestHistoryEntries(_:)` for bounded history
or provide an async custom transform. Bounded retention keeps only whole
prompt-led turns, so it may retain fewer entries than the limit rather than
orphaning a tool call or output. The file store hashes keys before using them as
filenames and writes atomically.

Important Foundation Models persistence behavior in Xcode 27:

- image attachments are encoded into the checkpoint and can make files large;
- decoded images retain pixels but may lose the original URL;
- custom segments retain data but decode through Foundation Models' erased
  representation rather than their original concrete Swift type;
- custom metadata values similarly lose concrete type identity;
- credentials, model configuration, tools, closures, and dynamic-profile state
  are not part of a transcript and must be reinjected.

`FileCheckpointStore` rejects custom segments and typed metadata by default,
because their concrete Swift types cannot be restored losslessly. Supply
`.allowFoundationModelsTypeErasure` only when the provider explicitly supports
the erased representation or your app rehydrates it. In-memory checkpoints do
not cross a Codable boundary and preserve the concrete values.

Encrypt sensitive checkpoint files at the application boundary. CoreAgent's
plain file store is intentionally not presented as encrypted storage.

## Production long-term memory

`CoreAgentMemory` is a separate, optional product. Checkpoints resume one native
transcript; long-term memory retrieves durable evidence across transcripts.
Neither store is a substitute for the other.

```swift
import CoreAgent
import CoreAgentMemory

let scope = try CoreAgentMemoryScope(
  applicationID: "com.example.assistant",
  userID: signedInUserID,
  agentID: "support"
)

let memoryStore = try SQLiteCoreAgentMemoryStore(
  databaseURL: URL.applicationSupportDirectory
    .appending(path: "CoreAgent/memory.sqlite")
)

let memory = CoreAgentMemoryCoordinator(
  scope: scope,
  store: memoryStore,
  disclosurePolicy: CoreAgentMemoryDisclosurePolicy(destination: .onDevice)
)

let agent = try CoreAgentSession(
  model: model,
  plugins: [memory]
)
```

String prompts automatically become the bounded retrieval query. Rich
`Prompt` values require an explicit `contextQuery:`; otherwise automatic recall
is skipped while `memory.searchTool` remains available. Retrieved records are
inserted before the original prompt as delimited, untrusted evidence, then
removed from active and checkpointed transcript history after generation.

SQLite is canonical and uses FTS5. It stores provenance, supersessions,
pending candidates, durable consolidation jobs, and tombstones with WAL and
foreign keys enabled. There is no vector-library dependency. Apps that need a
second retrieval strategy can implement `CoreAgentMemoryIndex`; CoreAgent
always reloads and filters canonical SQLite records before disclosure.

Successful runs persist an active episode before returning. A caller-supplied
`FoundationModelsMemoryConsolidator` uses fresh model sessions to propose facts,
preferences, or procedures. Proposals remain pending until an approval provider
or an explicit `approve(_:)` call accepts them. Use `flush()` at deterministic
test or shutdown boundaries.

See [Long-Term Memory](Documentation/Long-Term-Memory.md) for correction,
deletion, export, dynamic-profile, privacy, and failure-policy details.

## Traces and receipts

```swift
let observer = ClosureCoreAgentObserver { event in
  logger.info("\(event.kind.rawValue): \(event.message)")
}

let agent = try CoreAgentSession(
  model: model,
  observers: [observer]
)

let response = try await agent.respond(to: prompt)
let receipt = try CoreAgentRunReceipt(run: response.run)
precondition(receipt.verify())
```

Each observer has an independent, bounded serial queue, so a stalled observer
cannot stall a model, tool call, or another observer. The default queue keeps
256 pending events and drops the oldest on overflow; configure this with
`CoreAgentObserverDeliveryConfiguration`. `flushObservers()` distinguishes a
drained barrier from a timeout, cancellation, or reentrant call and reports the
cumulative number of dropped observer events:

```swift
let flush = await agent.flushObservers(timeout: .seconds(2))
guard flush.deliveredAllEvents else {
  logger.warning("Observer delivery did not drain before shutdown")
  return
}
```

Events record CoreAgent invocation IDs before execution. The post-response
transcript projection also records Foundation Models' authoritative tool-call
IDs. Prompt bodies, native tool arguments, and tool output bodies are not copied
into event attributes by default; they remain in the native transcript.

Receipts are SHA-256 hash chains. They detect mutation but do not prove
authorship; sign the root hash when cryptographic attribution is required.

## Streaming

```swift
let response = try await agent.respondStreaming(to: prompt) { partial in
  await viewModel.update(text: partial)
}
```

Typed streaming is available with `generating:`. The callback receives the
native `PartiallyGenerated` value, and the final result includes the complete
typed value and audited run. Response timeouts apply to streaming. A failed
stream may retry only before its first partial response and before any governed
tool begins, preventing duplicate UI output or side effects.

## Provider Traits

Every conforming `LanguageModel` already works with `CoreAgentSession`. The
optional `CoreAgentProviders` product adds one import and construction helpers
for the packages announced alongside Xcode 27.

Enable one or more SwiftPM Traits on the CoreAgent dependency:

```swift
.package(
  url: "https://github.com/rudrankriyam/CoreAgent.git",
  from: "0.2.0",
  traits: ["AppleUtilities", "Claude"]
)
```

Available traits:

| Trait | Package | CoreAgent helper |
| --- | --- | --- |
| `AppleUtilities` | `apple/foundation-models-utilities` | `openAICompatible(...)` |
| `Claude` | `anthropics/ClaudeForFoundationModels` | `claude(...)` |
| `Gemini` | Firebase AI Logic WWDC preview | `gemini(using:name:)` |
| `AllProviders` | All three | Enables every helper |

| Provider | iOS 27 | macOS 27 | visionOS 27 |
| --- | --- | --- | --- |
| Apple utilities | Yes | Yes | Yes |
| Claude | Yes | Yes | Yes |
| Gemini WWDC preview | Yes | Yes | Not officially supported |

Add `.product(name: "CoreAgentProviders", package: "CoreAgent")`, then:

```swift
import CoreAgent
import CoreAgentProviders
import Foundation
import FirebaseCore // Gemini trait only

let openAICompatible = CoreAgentProviderModels.openAICompatible(
  name: "gpt-5",
  baseURL: URL(string: "https://api.openai.com")!,
  headers: ["Authorization": "Bearer \(token)"]
)
let openAIAgent = try CoreAgentSession(model: openAICompatible)

let claude = CoreAgentProviderModels.claude(
  auth: .proxied(headers: ["Authorization": appSessionToken]),
  baseURL: URL(string: "https://your-relay.example.com")!
)
let claudeAgent = try CoreAgentSession(model: claude)

// Firebase requires a configured app and GoogleService-Info.plist first.
FirebaseApp.configure()
let gemini = CoreAgentProviderModels.gemini(
  using: FirebaseAIClient.firebaseAI(backend: .googleAI()),
  name: "gemini-2.5-flash"
)
let geminiAgent = try CoreAgentSession(model: gemini)
```

The Gemini example also requires `import FirebaseCore`, Firebase App Check, and
the normal Firebase AI Logic app setup. Do not call `firebaseAI()` before
`FirebaseApp.configure()`. Follow Firebase's
[Foundation Models setup guide](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started)
for the required `GoogleService-Info.plist` and App Check configuration.

Do not ship provider keys inside an app. Use a server relay or the provider's
production authentication path.

The Apple utility repository has no release tag yet and Firebase's adapter is a
WWDC preview, so CoreAgent pins both to verified commits. SwiftPM Traits avoid
compiling and linking disabled products. A clean SwiftPM 6.4 default resolution
uses no external packages; the Gemini trait is intentionally opt-in because its
current Firebase graph is exceptionally large.

The trait syntax above is for clients that own a `Package.swift`. Xcode 27's
Add Package UI does not currently expose dependency-trait selection. Xcode app
projects can add the desired upstream provider package directly and pass its
`LanguageModel` to `CoreAgentSession`; the helper product is optional and adds
no runtime capability.

## Test without keys or Apple Intelligence

`CoreAgentTestSupport` contains a native `RecordedLanguageModel` and executor.

```swift
import CoreAgent
import CoreAgentTestSupport

let model = RecordedLanguageModel(steps: [
  .toolCall(
    name: "lookup",
    argumentsJSON: #"{"query":"CoreAgent"}"#
  ),
  .response(text: "Recorded final response")
])

let agent = try CoreAgentSession(model: model, tools: [LookupTool()])
let response = try await agent.respond(to: "Test the flow")
```

No API key, network request, or local Apple model is involved. Captured native
request transcripts are available through `model.recorder` for assertions.
The provider-trait tests are construction/compilation smoke tests, not live API
integration tests.

Run the matrix:

```bash
swift test
swift test --traits AppleUtilities
swift test --traits Claude
swift test --traits Gemini
swift test --traits AllProviders
```

## Deliberate boundaries

Foundation Models owns the inner model/tool loop. Consequently CoreAgent does
not claim it can generically provide:

- direct-return or action-only semantics after an arbitrary native tool;
- model-planned tool ordering or per-model-step call limits;
- inspection, truncation, or sanitization of an arbitrary tool's opaque
  `Prompt` output before the model consumes it;
- Foundation Models' native tool-call ID before `Tool.call` begins.

Tools owned by a dynamic profile also stay outside CoreAgent's pre-execution
policy wrapper. Their lifecycle audit is best effort: a throwing inner profile
hook can prevent CoreAgent's observer from seeing a completed effect. Use the
explicit tools initializer for governance and audit guarantees.

CoreAgent can deny calls, enforce a total budget, time out execution, apply
policy decisions, and audit the authoritative transcript afterward. Strong
output filtering belongs in a CoreAgent-owned tool whose output contract is
inspectable.

Automatic retries stop as soon as a governed tool invocation begins, including
authorization. Apps may explicitly set `allowsRetryAfterToolInvocation` only
when every side effect is idempotent.
Checkpoint write failures are recorded and return the completed model response
by default; select `.failRun` only when callers will not blindly repeat side
effects.

## License

CoreAgent is available under the MIT license.
