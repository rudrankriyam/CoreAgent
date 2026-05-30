# KarmaKit

KarmaKit is a Swift framework for building agentic apps on Apple platforms: tool calling, memory, model providers, and local-first workflows.

The core idea is simple: describe what an agent can do, let a model choose the right action, and keep every step visible.

The name "Karma" comes from the Sanskrit word कर्म (karma), which means "action" or "deed." That is the point of the library: agents that can take useful, inspectable actions with minimal setup.

## Goals

- Swift-native agent primitives.
- Tiny public surface area.
- Model-provider agnostic by default.
- Tool calling as the first workflow.
- Memory that can be inspected, replayed, and debugged.
- Ready for Apple platform integrations such as Foundation Models, App Intents, Shortcuts, and local RAG.

## Quick Start

```swift
import KarmaKit
import KarmaKitFoundationModels

if #available(macOS 26.0, iOS 26.0, *) {
  let provider = FoundationModelProvider()
  let agent = ToolCallingAgent(tools: [], model: provider)
  let run = try await agent.run("Explain tool calling in one sentence.")

  print(run.finalAnswer)
}
```

Model providers conform to `ModelProvider` and return either tool calls or a final answer.

## CLI

```bash
swift run karma "Explain tool calling in one sentence"
swift run karma --demo-tools "Use the multiply tool to multiply 12 by 13. Return only the number."
swift run karma --demo-tools --list-tools
swift run karma --demo-tools --print-config
swift run karma --demo-tools --print-discovery
swift run karma --verbose --demo-tools "What time is it? Use the available action."
swift run karma --stream "Write one sentence about local agents."
swift run karma --parallel-tools --demo-tools "Use the available actions when helpful."
swift run karma --action-only --demo-tools "Calculate 7 * 6, then call done with the result."
swift run karma --fail-on-tool-argument-error --demo-tools "Use the available actions when helpful."
swift run karma --fail-on-final-answer-rejection --demo-tools "Use the available actions when helpful."
swift run karma --trace /tmp/karma-trace.json "Explain tool calling in one sentence."
swift run karma --receipt /tmp/karma-receipt.json "Explain tool calling in one sentence."
swift run karma --verify-receipt /tmp/karma-receipt.json --verify-trace /tmp/karma-trace.json
swift run karma --no-redaction --trace /tmp/karma-trace.json "Explain tool calling in one sentence."
swift run karma --max-model-input-chars 12000 "Summarize this request."
swift run karma --max-tool-output-chars 4000 --demo-tools "Search files for local agents and summarize the matches."
swift run karma --max-context-messages 12 --demo-tools "Use recent context and answer briefly."
swift run karma --max-memory-messages 40 --demo-tools "Keep memory compact while answering."
swift run karma --model-timeout-seconds 30 "Answer with a bounded model call."
swift run karma --run-timeout-seconds 60 "Answer within a bounded run."
swift run karma --structured-demo "Summarize Foundation Models agents."
swift run karma --demo-tools "Use calculate to evaluate 2 + 3 * 5. Return only the result."
swift run karma --demo-tools --allow-file-dir /tmp "Read /tmp/example.txt and summarize it."
swift run karma --demo-tools --allow-file-dir /tmp "Search files for local agents and summarize the matches."
swift run karma --demo-tools --allow-url-host example.com "Fetch https://example.com and summarize it."
```

## Current Foundation

- `Tool`: describes and runs a callable action.
- `ClosureTool`: lightweight tool wrapper for examples and simple actions.
- `ModelProvider`: abstraction for local, hosted, or Apple-provided models.
- `ToolCallingAgent`: minimal loop that asks a model for tool calls or a final answer.
- `ToolCallingAgent` serializes runs per instance so shared agent memory stays consistent.
- `AgentConfiguration`: persists safe runtime settings and approved tool manifests.
- `AgentDiscoveryDocument`: exports redacted agent metadata for discovery files such as `/.well-known/agent.json`.
- `ToolCallExecutionMode`: runs multiple tool calls sequentially or in parallel.
- `ToolArgumentErrorRecoveryMode`: turns invalid tool arguments into retryable tool feedback, with opt-in fail-fast behavior.
- `FinalAnswerRecoveryMode`: turns rejected final answers into retryable model feedback, with opt-in fail-fast behavior.
- `AgentCompletionMode`: supports final-answer runs and action-only runs that finish through a completion tool.
- `AgentCancellation`: interrupts runs with an inspectable reason.
- `ToolManifest`: stable digest for approving and auditing tool definitions.
- `ToolInput`: validates nested object properties and array items before execution.
- `AgentMemory`: stores messages and action steps.
- `FoundationModelProvider`: Apple Foundation Models backend.
- `FoundationModelToolAdapter`: bridges KarmaKit tools into Foundation Models tools.
- `FoundationModelToolAudit`: records Foundation Models-native tool authorization events.
- `ToolExecutionPolicy`: authorizes tool calls before execution.
- `toolCallAuthorized` and `toolCallDenied`: record policy decisions before tool execution.
- `TrustedToolExecutionPolicy`: only allows tools with approved manifest digests.
- `TrustedExternalToolExecutionPolicy`: only allows external tools with approved manifests and trust identities.
- `CompositeToolExecutionPolicy` and `ToolNameAllowlistExecutionPolicy`: stack governance checks before any tool runs.
- `ActionCompletionTool`: lets action-only agents mark work complete after tool-side state has been updated.
- `DirectReturnTool`: lets an authoritative tool result complete the run without another model turn.
- `ToolOutputSanitizer`: marks instruction-like tool output as untrusted data.
- `PromptInjectionShieldValidator`: rejects answers that repeat untrusted tool-output instructions.
- `ManagedAgentTool`: exposes an agent as a callable tool.
- `ManagedAgentMemoryPolicy`: runs delegated agents with isolated memory by default, with opt-in retained memory.
- `ManagedAgentRunReport`: preserves delegated agent messages, events, and metrics in parent tool results.
- `ManagedAgentToolError`: preserves failed delegated agent run reports for parent failure events.
- `AgentObserver`: records run, model, tool, and answer events.
- `AgentEventTrace`: links events with run, event, span, and parent span IDs.
- `AgentEvent`: carries structured failure type and description for audit trails.
- `toolCallFailed`: records tool-level errors with call, manifest, and failure metadata.
- `AgentRun.snapshot`: exports in-progress or failed memory for debugging artifacts.
- `AgentRunMetrics`: summarizes steps, retries, tool calls, interruptions, usage, and duration.
- `FinalAnswerValidator`: validates answers before a run succeeds.
- `RetryPolicy`: retries transient model failures.
- `AgentTimeouts`: limits long-running runs, model generation, and tool calls.
- `AgentLimits`: caps oversized model input and tool output before they create brittle runs.
- `AgentLimits.maximumContextMessages`: keeps model input bounded while preserving full run memory.
- `AgentLimits.maximumMemoryMessages`: compacts retained memory before long-lived runs continue.
- `AgentLimits.maximumToolCallsPerStep`: rejects excessive tool fan-out before execution.
- `ConversationCompactor`, `AgentMemorySummary`, `ExcerptConversationCompactor`, and `ModelConversationCompactor`: preserve semantic memory, preferences, decisions, open threads, durable facts, and important tool results.
- `AgentMessageNormalizer`: merges compatible consecutive messages before provider calls.
- `StreamingModelProvider`: streams partial responses when a provider supports it.
- `AgentRedactionPolicy`: removes token-like values from exported traces and receipts by default.
- `FileAgentMemoryStore`: saves and reloads agent memory as JSON.
- Persisted memory is re-anchored to the agent's configured system prompt before use.
- `AgentTraceExporter`: writes run traces for debugging and audits.
- `AgentReceiptExporter`: writes and verifies tamper-evident run receipts.
- `FoundationModelSchemaAdapter`: builds nested Foundation Models schemas from KarmaKit tool inputs.
- `KarmaKitTools`: reusable tools for current time, arithmetic, whitelisted file reads, and local text search.
- `URLFetchTool`: fetches allowlisted public HTTP(S) URLs with SSRF checks, timeout, status, and size limits.

## Roadmap

- App Intents bridge.
- Shortcuts bridge.
- Local RAG examples.
- SwiftUI debugging view for agent runs.
- SwiftData or SQLite memory store.

## Contributing

KarmaKit is an open-source project, and contributions are always welcome.

[![Star History Chart](https://api.star-history.com/svg?repos=rryam/KarmaKit&type=Date)](https://star-history.com/#rryam/KarmaKit&Date)
