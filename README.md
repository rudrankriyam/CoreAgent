# KarmaKit

A Swift agent runtime for Apple Foundation Models.

KarmaKit gives Apple-platform apps a small, inspectable foundation for tool-calling agents: Swift-native tools, structured memory, approval gates, run traces, receipts, and a Foundation Models backend that stays local to the Apple stack.

The name "Karma" comes from the Sanskrit word कर्म (karma), meaning "action" or "deed." That is the point of the library: agents that can take useful, auditable actions with minimal setup.

## Why KarmaKit

- **Foundation Models first:** built for Apple's Foundation Models framework on iOS, macOS, and visionOS 26.
- **Swift-native tools:** describe callable actions with strong metadata, input schemas, output descriptions, and stable manifests.
- **App-grade governance:** approve, deny, allowlist, or trust tools before anything runs.
- **Durable memory:** keep conversation history, compact older messages into structured summaries, and persist runs as JSON.
- **Operational visibility:** export traces and tamper-evident receipts for debugging, QA, audits, and support workflows.
- **Composable agents:** expose one agent as a tool for another while preserving delegated run reports.

## Requirements

- Swift 6.2
- iOS 26.0+
- macOS 26.0+
- visionOS 26.0+
- Xcode 26 SDKs with `FoundationModels`

## Installation

Add KarmaKit with Swift Package Manager:

```swift
.package(url: "https://github.com/rryam/KarmaKit.git", branch: "main")
```

Then add the products you need to your target:

```swift
.product(name: "KarmaKit", package: "KarmaKit"),
.product(name: "KarmaKitFoundationModels", package: "KarmaKit"),
.product(name: "KarmaKitTools", package: "KarmaKit")
```

## Quick Start

```swift
import KarmaKit
import KarmaKitFoundationModels

let provider = FoundationModelProvider(
  instructions: "Answer clearly and use tools when they are useful."
)

let agent = ToolCallingAgent(
  tools: [],
  model: provider
)

let run = try await agent.run("Explain tool calling in one sentence.")
print(run.finalAnswer)
```

`ToolCallingAgent` keeps a run loop around `FoundationModelProvider`. The model can either return a final answer or request one or more tool calls, and KarmaKit records each step in memory and events.

## Add Tools

Tools are plain Swift types that conform to `Tool`, or lightweight closures when that is enough:

```swift
import KarmaKit

let slugify = ClosureTool(
  name: "slugify",
  description: "Convert text into a lowercase URL slug.",
  outputDescription: "A lowercase slug separated by hyphens.",
  inputs: [
    "text": ToolInput(
      type: .string,
      description: "Text to convert into a slug."
    )
  ]
) { arguments in
  arguments["text", default: ""]
    .lowercased()
    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    .joined(separator: "-")
}

let agent = ToolCallingAgent(
  tools: [slugify],
  model: FoundationModelProvider()
)

let run = try await agent.run(
  "Use slugify for 'Foundation Models Agent Runtime'. Return only the slug."
)
```

Each tool can publish a `ToolManifest` containing its name, description, inputs, output description, and digest. Those manifests are used for trust checks, discovery documents, and configuration verification.

## Foundation Models

`KarmaKitFoundationModels` provides the Apple-native backend:

- `FoundationModelProvider` implements `ModelProvider` and `StreamingModelProvider`.
- `FoundationModelToolAdapter` bridges KarmaKit tools into Foundation Models tools.
- `FoundationModelSchemaAdapter` converts `ToolInput` trees into Foundation Models schemas.
- `FoundationModelToolAudit` records Foundation Models-native tool authorization events.

Structured generation is available directly from the provider:

```swift
let provider = FoundationModelProvider()

let output = try await provider.generateStructuredContent(
  prompt: "Summarize this agent run.",
  schemaName: "RunSummary",
  schemaDescription: "A short structured summary of an agent run.",
  properties: [
    "title": ToolInput(type: .string, description: "A short title."),
    "summary": ToolInput(type: .string, description: "One sentence summary."),
    "tags": .array(
      description: "Two to four lowercase tags.",
      items: ToolInput(type: .string, description: "A tag.")
    )
  ]
)
```

## CLI

KarmaKit ships with a `karma` executable for local testing:

```bash
swift run karma "Explain tool calling in one sentence."
swift run karma --stream "Write one sentence about local agents."
swift run karma --structured-demo "Summarize Foundation Models agents."
```

Try tools, manifests, and discovery output:

```bash
swift run karma --demo-tools "Use calculate to evaluate 2 + 3 * 5. Return only the result."
swift run karma --demo-tools --list-tools
swift run karma --demo-tools --print-config
swift run karma --demo-tools --print-discovery
```

Capture and verify run artifacts:

```bash
swift run karma --trace /tmp/karma-trace.json --receipt /tmp/karma-receipt.json "Explain tool calling."
swift run karma --verify-receipt /tmp/karma-receipt.json --verify-trace /tmp/karma-trace.json
```

Bound long runs and tool-heavy workflows:

```bash
swift run karma --model-timeout-seconds 30 "Answer with a bounded model call."
swift run karma --run-timeout-seconds 60 "Answer within a bounded run."
swift run karma --max-model-input-chars 12000 "Summarize this request."
swift run karma --max-tool-output-chars 4000 --demo-tools "Search files and summarize the matches."
swift run karma --max-context-messages 12 --max-memory-messages 40 --demo-tools "Answer with bounded context."
```

Use allowlisted local files and hosts:

```bash
swift run karma --demo-tools --allow-file-dir /tmp "Read /tmp/example.txt and summarize it."
swift run karma --demo-tools --allow-url-host example.com "Fetch https://example.com and summarize it."
```

## Core Building Blocks

| Area | APIs | What it gives you |
| --- | --- | --- |
| Agent loop | `ToolCallingAgent`, `ModelProvider`, `StreamingModelProvider` | A bounded run loop that asks the model for tool calls or a final answer. |
| Tools | `Tool`, `ClosureTool`, `ToolInput`, `ToolManifest` | Swift actions with schemas, descriptions, and stable approval digests. |
| Foundation Models | `FoundationModelProvider`, `FoundationModelToolAdapter`, `FoundationModelSchemaAdapter` | Apple-native generation, structured content, and tool bridging. |
| Governance | `ToolExecutionPolicy`, `TrustedToolExecutionPolicy`, `ApprovalRequiredToolExecutionPolicy`, `CompositeToolExecutionPolicy` | Authorization before tool execution. |
| Memory | `AgentMemory`, `FileAgentMemoryStore`, `ConversationCompactor`, `AgentMemorySummary`, `ModelConversationCompactor` | Persisted conversation state with structured compaction. |
| Context | `AgentContextProvider`, `StaticAgentContextProvider`, `AgentContextProviderManifest`, `TrustedAgentContextProviderExecutionPolicy` | Trusted pre-generation context without writing it into run memory. |
| Delegation | `ManagedAgentTool`, `ManagedAgentRunReport`, `ManagedAgentMemoryPolicy` | Agent-to-agent calls with isolated or retained delegated memory. |
| Observability | `AgentObserver`, `AgentEvent`, `AgentEventTrace`, `AgentRunMetrics`, `AgentTraceExporter`, `AgentReceiptExporter` | Inspectable events, metrics, traces, and verifiable receipts. |
| Safety | `ToolOutputSanitizer`, `PromptInjectionShieldValidator`, `AgentRedactionPolicy`, `AgentLimits`, `AgentTimeouts` | Untrusted tool-output handling, redaction, limits, and timeouts. |

## Trusted Tools and Context

KarmaKit can persist an agent configuration and verify that tools or context providers have not drifted before the agent runs again:

```swift
let tools: [any Tool] = [slugify]

let agent = ToolCallingAgent(
  tools: tools,
  model: FoundationModelProvider()
)

let configuration = try agent.configuration()
try configuration.verifyTools(tools)

let rebuilt = try ToolCallingAgent(
  configuration: configuration,
  tools: tools,
  model: FoundationModelProvider()
)
```

Use `TrustedToolExecutionPolicy` or `TrustedAgentContextProviderExecutionPolicy` when a run should only accept approved manifests.

## Approval Gates

Apps can route selected tool calls through an approval provider:

```swift
let approval = ClosureToolApprovalProvider { context in
  context.call.name == "send_email" ? .denied(reason: "User approval required.") : .approved
}

let policy = ApprovalRequiredToolExecutionPolicy(
  requiredToolNames: ["send_email"],
  provider: approval
)

let agent = ToolCallingAgent(
  tools: tools,
  model: FoundationModelProvider(),
  toolExecutionPolicy: policy
)
```

Policies compose, so an app can combine allowlists, approved manifests, external trust identities, and interactive approval.

## Memory and Context

KarmaKit separates retained memory from injected context:

- `AgentMemory` records system, user, assistant, and tool messages plus action steps and events.
- `FileAgentMemoryStore` saves and reloads memory as JSON.
- `ConversationCompactor` converts older messages into an `AgentMemorySummary`.
- `ModelConversationCompactor` asks the configured model to preserve semantic summaries, user preferences, decisions, open threads, durable facts, and important tool results.
- `AgentContextProvider` injects trusted context before generation without persisting it into the run.

```swift
let memoryStore = FileAgentMemoryStore(
  fileURL: URL(fileURLWithPath: "/tmp/karma-memory.json")
)

let agent = ToolCallingAgent(
  tools: tools,
  model: FoundationModelProvider(),
  resetsMemoryBeforeRun: false,
  limits: AgentLimits(maximumMemoryMessages: 40),
  memoryStore: memoryStore,
  conversationCompactor: ModelConversationCompactor(
    model: FoundationModelProvider()
  )
)
```

## Traces and Receipts

Run artifacts are first-class:

```swift
let run = try await agent.run("Use the available tools and summarize the result.")

try AgentTraceExporter().write(
  run,
  to: URL(fileURLWithPath: "/tmp/karma-trace.json")
)

try AgentReceiptExporter().write(
  run,
  to: URL(fileURLWithPath: "/tmp/karma-receipt.json")
)
```

Traces are useful for debugging and support. Receipts contain a hash chain that can be verified later with the CLI.

## Package Layout

- `KarmaKit`: core agent loop, tool contracts, memory, policies, traces, receipts, and run metrics.
- `KarmaKitFoundationModels`: Apple Foundation Models provider and schema/tool adapters.
- `KarmaKitTools`: reusable tools for time, arithmetic, allowlisted file reads, local text search, and allowlisted URL fetches.
- `karma`: local CLI for running prompts, trying tools, printing manifests, and exporting artifacts.

## Roadmap

- App Intents bridge.
- Shortcuts bridge.
- SwiftUI run inspector.
- SwiftData and SQLite memory stores.
- Local retrieval examples for app-private knowledge.

## Contributing

Issues, ideas, and pull requests are welcome. Keep contributions focused on Apple-native agent workflows, inspectable execution, and APIs that feel natural in Swift apps.

[![Star History Chart](https://api.star-history.com/svg?repos=rryam/KarmaKit&type=Date)](https://star-history.com/#rryam/KarmaKit&Date)
