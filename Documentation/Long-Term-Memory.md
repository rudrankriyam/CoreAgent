# Long-Term Memory

`CoreAgentMemory` adds local, inspectable memory without changing Foundation
Models' `LanguageModel`, `Prompt`, `Transcript`, `Tool`, or `Generable` types.
It is optional and has no embedding, vector-database, graph, or cloud
dependency.

## Checkpoints and long-term memory

| Concern | Transcript checkpoint | Long-term memory |
| --- | --- | --- |
| Purpose | Resume one native session | Recall durable evidence across sessions |
| Canonical value | Foundation Models `Transcript` | `CoreAgentMemoryRecord` |
| Default store | `FileCheckpointStore` | `SQLiteCoreAgentMemoryStore` |
| Retrieval | Restore full retained history | Scoped FTS5 plus an optional index |
| Deletion | Remove the checkpoint key | Tombstone first, then purge derivatives |

The products do not migrate data between these stores. Adding memory does not
change checkpoint format or checkpoint ownership.

## Configure a scoped coordinator

Every coordinator requires application, user, and agent identifiers. Search,
approval, correction, export, and deletion never fall back across a missing
scope component.

```swift
import CoreAgent
import CoreAgentMemory

let scope = try CoreAgentMemoryScope(
  applicationID: "com.example.assistant",
  userID: user.id,
  agentID: "research"
)

let store = try SQLiteCoreAgentMemoryStore(
  databaseURL: URL.applicationSupportDirectory
    .appending(path: "Memory/research.sqlite")
)

let memory = CoreAgentMemoryCoordinator(
  scope: scope,
  store: store,
  disclosurePolicy: .init(destination: .onDevice)
)

let session = try CoreAgentSession(model: model, plugins: [memory])
```

`SQLiteCoreAgentMemoryStore` enables WAL, foreign keys, and an FTS5 index. Its
default protection is `completeUntilFirstUserAuthentication`; database, WAL,
and shared-memory files are excluded from backup by default. These settings are
configurable when an app has a different data-protection or backup policy.

## Recall

String response APIs use the prompt text as `contextQuery`:

```swift
let response = try await session.respond(to: "What color did I choose?")
```

Rich prompts do not have a safe universal text projection. Supply the query
explicitly when automatic recall is wanted:

```swift
let response = try await session.respond(
  to: Prompt {
    Attachment(image)
    "Compare this design with my saved preference."
  },
  contextQuery: "saved design and color preferences"
)
```

Recall overfetches candidate identifiers, reloads canonical records, then
enforces exact scope, active status, temporal validity, disclosure sensitivity,
and tombstones. Results use deterministic relevance, authority, recency, and ID
ordering. The default prompt budget is eight records and 6,000 characters.
Record boundaries and provenance are preserved, and truncation is labeled.

The injected block is explicitly marked untrusted evidence. It is placed before
the original prompt, never in instructions. CoreAgent verifies and removes the
exact injected segments after the run, checkpoints only the sanitized
transcript, and rebuilds the explicit native session from that transcript. Raw
response entries remain on `CoreAgentResponse` for audit.

The coordinator also exposes a read-only `coreagent_search_memory` tool. In an
explicit-model session the plugin contributes this tool to CoreAgent's normal
manifest, duplicate-name validation, policy, audit, and checkpoint revision.

## Capture and consolidation

After a successful run, CoreAgent transactionally stores an immutable episode
and its durable consolidation job before returning the model response. Episode
content excludes instructions, hidden reasoning, automatically injected
evidence, and memory-search tool output. Image and custom inputs retain source
or asset identifiers without copying their binary data into a record.

Consolidation is optional:

```swift
let consolidator = FoundationModelsMemoryConsolidator(model: consolidationModel)

let memory = CoreAgentMemoryCoordinator(
  scope: scope,
  store: store,
  disclosurePolicy: .init(destination: .remote),
  consolidator: consolidator,
  approvalProvider: DeferCoreAgentMemoryApprovalProvider()
)
```

Each job gets a fresh `LanguageModelSession`; it never receives or modifies the
user-facing session. Proposed facts, preferences, procedures, and reflections
remain pending. Review them with `pendingCandidates()`, then call `approve(_:)`
or `reject(_:reason:)`. An approval provider may automate the same decision.

Queued and interrupted jobs resume when the coordinator is constructed. A job
gets at most three attempts. Terminal failures are available through
`consolidationFailures()` and can be reset with
`retryFailedConsolidation()`. `flush()` waits for consolidation and scheduled
index repair.

## Direct lifecycle APIs

```swift
let fact = try await memory.remember(
  "The user prefers compact layouts.",
  kind: .preference,
  authority: .priorUserStatement
)

let correction = try await memory.correct(
  recordIDs: [fact.id],
  with: "The user now prefers spacious layouts."
)

let matches = try await memory.search("layout preference")
try await memory.forget(correction.id) // durable tombstone, no recall
try await memory.purge(correction.id)  // hard-delete canonical and derivatives
```

Corrections append a new record with `explicitUserCorrection` authority and
supersede prior records. They never overwrite provenance. Authority wins before
recency when equally relevant records conflict.

`forget(_:)` writes the tombstone before attempting optional-index or export
cleanup, so a stale derivative cannot pass canonical filtering. `purge(_:)` and
scope-wide `purge()` remove records, FTS rows, candidates, jobs, tombstones,
optional-index documents, and registered Markdown exports.

## Markdown export

```swift
let manifest = try await memory.exportMarkdown(
  to: exportDirectory
)
```

Export writes one lowercase `<record-id>.md` file per non-tombstoned record and
a sorted, versioned `manifest.json`. Files are protected and excluded from
backup by default. Imports are not supported in this release.

## Dynamic profiles

Dynamic-profile state can include non-transcript values that CoreAgent cannot
rebuild safely. Automatic prompt injection is therefore disabled in profile
mode. Episode capture and consolidation still run. Put the search tool in the
profile explicitly when recall is required:

```swift
let session = try CoreAgentSession(
  checkpointCompatibilityID: "assistant-profile-v1",
  plugins: [memory]
) {
  LanguageModelSession.Profile {
    Instructions("Help with the current project.")
    memory.searchTool
  }
  .model(model)
}
```

## Privacy and failure policy

The disclosure policy must declare whether the destination model is on-device
or remote. Remote defaults exclude `restricted` records. Apps can provide an
explicit sensitivity allowlist. Embeddings or other optional-index values are
sensitive derivatives even though CoreAgent does not create them itself.

Memory events contain IDs, counts, stages, and error types, not record bodies.
Preparation and write failures default to recording the failure and preserving
the model response. Apps may select `failRun`; a completion failure can occur
after model or tool side effects, so callers must not blindly retry it.
Transcript-sanitization mismatches fail by default. If configured to continue,
CoreAgent reverts to the pre-run transcript rather than retaining injected
evidence.

Neural state, KV-cache import/export, and latent-memory representations are not
part of this product.
