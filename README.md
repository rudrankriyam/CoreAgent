# CoreAgent

A Swift runtime for on-device agents on Apple platforms.

CoreAgent gives Apple-platform apps a small, inspectable foundation for on-device agents: Swift-native tools, structured memory, approval gates, run traces, receipts, and a Foundation Models backend that stays local to the Apple stack.

It is built around Apple Foundation Models today and designed to grow with the broader local AI surface across iOS, macOS, and visionOS.

## Why CoreAgent

- **Foundation Models first:** built for Apple's Foundation Models framework on iOS, macOS, and visionOS 27.
- **Swift-native tools:** describe callable actions with strong metadata, input schemas, output descriptions, and stable manifests.
- **App-grade governance:** approve, deny, allowlist, or trust tools before anything runs.
- **Durable memory:** keep conversation history, compact older messages into structured summaries, and persist runs as JSON.
- **Operational visibility:** export traces and tamper-evident receipts for debugging, QA, audits, and support workflows.
- **Composable agents:** expose one agent as a tool for another while preserving delegated run reports.

## Requirements

- Swift 6.4
- iOS 27.0+
- macOS 27.0+
- visionOS 27.0+
- Xcode 27 SDKs with `FoundationModels`

## Installation

Add CoreAgent with Swift Package Manager:

```swift
.package(url: "https://github.com/rudrankriyam/CoreAgent.git", branch: "main")
```

Then add the products you need to your target:

```swift
.product(name: "CoreAgent", package: "CoreAgent"),
.product(name: "CoreAgentFoundationModels", package: "CoreAgent"),
.product(name: "CoreAgentTools", package: "CoreAgent")
```

## Quick Start

```swift
import CoreAgent
import CoreAgentFoundationModels

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

`ToolCallingAgent` keeps a run loop around `FoundationModelProvider`. The model can either return a final answer or request one or more tool calls, and CoreAgent records each step in memory and events.

## Add Tools

Tools are plain Swift types that conform to `Tool`, or lightweight closures when that is enough:

```swift
import CoreAgent

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

`CoreAgentFoundationModels` provides the OS 27 Foundation Models backend:

- `FoundationModelProvider` implements `ModelProvider` and `StreamingModelProvider`.
- `FoundationModelRuntime` selects either `SystemLanguageModel` or `PrivateCloudComputeLanguageModel`.
- `FoundationModelRuntimeSelection` chooses on-device generation, Private Cloud Compute, or PCC when it is available.
- `FoundationModelRuntimeSnapshot` reports availability, context size, capabilities, locale support, and PCC quota state.
- `FoundationModelToolAdapter` bridges CoreAgent tools into Foundation Models tools.
- `FoundationModelSchemaAdapter` converts `ToolInput` trees into Foundation Models schemas.
- `FoundationModelToolAudit` records Foundation Models-native tool authorization events.
- `ContextOptions` can be passed through for OS 27 reasoning levels and schema prompting.

Use Private Cloud Compute when your app has the required entitlement, or let CoreAgent choose PCC when it is available:

```swift
let provider = FoundationModelProvider(
  runtime: .privateCloudCompute(PrivateCloudComputeLanguageModel()),
  contextOptions: ContextOptions(reasoningLevel: .deep)
)

let adaptiveProvider = FoundationModelProvider(
  selection: .preferPrivateCloudCompute(),
  contextOptions: ContextOptions(reasoningLevel: .moderate)
)
```

Tune tool use with OS 27's Foundation Models generation options:

```swift
let provider = FoundationModelProvider(
  options: GenerationOptions(
    temperature: 0.7,
    maximumResponseTokens: 512,
    toolCallingMode: .required
  )
)
```

Inspect the active runtime before a run:

```swift
let snapshot = await provider.runtimeSnapshot()
print(snapshot.kind)
print(snapshot.supportsReasoning)
print(snapshot.privateCloudComputeQuota?.statusDescription)
```

Pass Foundation Models prompts directly when you need OS 27 prompt-builder features such as image attachments:

```swift
let imagePrompt = Prompt {
  Attachment(image).label("reference")
  "Describe the craft project in this reference image."
}

let output = try await provider.generate(prompt: imagePrompt)
```

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

CoreAgent ships with a `core-agent` executable for local testing:

```bash
swift run core-agent "Explain tool calling in one sentence."
swift run core-agent --stream "Write one sentence about local agents."
swift run core-agent --structured-demo "Summarize Foundation Models agents."
```

Try tools, manifests, and discovery output:

```bash
swift run core-agent --demo-tools "Use calculate to evaluate 2 + 3 * 5. Return only the result."
swift run core-agent --demo-tools --list-tools
swift run core-agent --demo-tools --print-config
swift run core-agent --demo-tools --print-discovery
```

Capture and verify run artifacts:

```bash
swift run core-agent --trace /tmp/core-agent-trace.json --receipt /tmp/core-agent-receipt.json "Explain tool calling."
swift run core-agent --verify-receipt /tmp/core-agent-receipt.json --verify-trace /tmp/core-agent-trace.json
```

Bound long runs and tool-heavy workflows:

```bash
swift run core-agent --model-timeout-seconds 30 "Answer with a bounded model call."
swift run core-agent --run-timeout-seconds 60 "Answer within a bounded run."
swift run core-agent --max-model-input-chars 12000 "Summarize this request."
swift run core-agent --max-response-tokens 512 "Keep the answer short."
swift run core-agent --max-tool-output-chars 4000 --demo-tools "Search files and summarize the matches."
swift run core-agent --max-context-messages 12 --max-memory-messages 40 --demo-tools "Answer with bounded context."
```

Try OS 27 Foundation Models controls:

```bash
swift run core-agent --print-model-info
swift run core-agent --pcc --print-model-info
swift run core-agent --prefer-pcc --reasoning deep "Plan this workflow."
swift run core-agent --tool-calling required --demo-tools "Use calculate for 12 * 9."
swift run core-agent --temperature 0.8 --max-response-tokens 256 "Brainstorm five names."
```

Use allowlisted local files and hosts:

```bash
swift run core-agent --demo-tools --allow-file-dir /tmp "Read /tmp/example.txt and summarize it."
swift run core-agent --demo-tools --allow-url-host example.com "Fetch https://example.com and summarize it."
```

## Core Building Blocks

| Area | APIs | What it gives you |
| --- | --- | --- |
| Agent loop | `ToolCallingAgent`, `ModelProvider`, `StreamingModelProvider` | A bounded run loop that asks the model for tool calls or a final answer. |
| Tools | `Tool`, `ClosureTool`, `ToolInput`, `ToolManifest` | Swift actions with schemas, descriptions, and stable approval digests. |
| Foundation Models | `FoundationModelProvider`, `FoundationModelRuntime`, `FoundationModelRuntimeSelection`, `FoundationModelRuntimeSnapshot`, `FoundationModelToolAdapter`, `FoundationModelSchemaAdapter` | OS 27 generation, PCC selection, runtime inspection, structured content, and tool bridging. |
| Governance | `ToolExecutionPolicy`, `TrustedToolExecutionPolicy`, `ApprovalRequiredToolExecutionPolicy`, `CompositeToolExecutionPolicy` | Authorization before tool execution. |
| Memory | `AgentMemory`, `FileAgentMemoryStore`, `ConversationCompactor`, `AgentMemorySummary`, `ModelConversationCompactor` | Persisted conversation state with structured compaction. |
| Context | `AgentContextProvider`, `StaticAgentContextProvider`, `AgentContextProviderManifest`, `TrustedAgentContextProviderExecutionPolicy` | Trusted pre-generation context without writing it into run memory. |
| Delegation | `ManagedAgentTool`, `ManagedAgentRunReport`, `ManagedAgentMemoryPolicy` | Agent-to-agent calls with isolated or retained delegated memory. |
| Observability | `AgentObserver`, `AgentEvent`, `AgentEventTrace`, `AgentRunMetrics`, `AgentTraceExporter`, `AgentReceiptExporter` | Inspectable events, metrics, traces, and verifiable receipts. |
| Safety | `ToolOutputSanitizer`, `PromptInjectionShieldValidator`, `AgentRedactionPolicy`, `AgentLimits`, `AgentTimeouts` | Untrusted tool-output handling, redaction, limits, and timeouts. |

## Trusted Tools and Context

CoreAgent can persist an agent configuration and verify that tools or context providers have not drifted before the agent runs again:

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

CoreAgent separates retained memory from injected context:

- `AgentMemory` records system, user, assistant, and tool messages plus action steps and events.
- `FileAgentMemoryStore` saves and reloads memory as JSON.
- `ConversationCompactor` converts older messages into an `AgentMemorySummary`.
- `ModelConversationCompactor` asks the configured model to preserve semantic summaries, user preferences, decisions, open threads, durable facts, and important tool results.
- `AgentContextProvider` injects trusted context before generation without persisting it into the run.

```swift
let memoryStore = FileAgentMemoryStore(
  fileURL: URL(fileURLWithPath: "/tmp/core-agent-memory.json")
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
  to: URL(fileURLWithPath: "/tmp/core-agent-trace.json")
)

try AgentReceiptExporter().write(
  run,
  to: URL(fileURLWithPath: "/tmp/core-agent-receipt.json")
)
```

Traces are useful for debugging and support. Receipts contain a hash chain that can be verified later with the CLI.

## Package Layout

- `CoreAgent`: core agent loop, tool contracts, memory, policies, traces, receipts, and run metrics.
- `CoreAgentFoundationModels`: Apple Foundation Models provider and schema/tool adapters.
- `CoreAgentTools`: reusable tools for time, arithmetic, allowlisted file reads, local text search, and allowlisted URL fetches.
- `core-agent`: local CLI for running prompts, trying tools, printing manifests, and exporting artifacts.

## Roadmap

- App Intents bridge.
- Shortcuts bridge.
- SwiftUI run inspector.
- SwiftData and SQLite memory stores.
- Local retrieval examples for app-private knowledge.

## Contributing

Issues, ideas, and pull requests are welcome. Keep contributions focused on Apple-native agent workflows, inspectable execution, and APIs that feel natural in Swift apps.

## Acknowledgements

CoreAgent is inspired by [Hugging Face smolagents](https://github.com/huggingface/smolagents): small agent loops, tool-first execution, and readable primitives. CoreAgent brings that spirit to Swift and Apple's on-device Foundation Models stack.

[![Star History Chart](https://api.star-history.com/svg?repos=rudrankriyam/CoreAgent&type=Date)](https://star-history.com/#rudrankriyam/CoreAgent&Date)
