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
```

## Current Foundation

- `Tool`: describes and runs a callable action.
- `ClosureTool`: lightweight tool wrapper for examples and simple actions.
- `ModelProvider`: abstraction for local, hosted, or Apple-provided models.
- `ToolCallingAgent`: minimal loop that asks a model for tool calls or a final answer.
- `AgentMemory`: stores messages and action steps.
- `FoundationModelProvider`: Apple Foundation Models backend.

## Roadmap

- Foundation Models tool bridge.
- App Intents bridge.
- Shortcuts bridge.
- SwiftData or SQLite memory store.
- Local RAG examples.
- SwiftUI debugging view for agent runs.

## Contributing

KarmaKit is an open-source project, and contributions are always welcome.

[![Star History Chart](https://api.star-history.com/svg?repos=rryam/KarmaKit&type=Date)](https://star-history.com/#rryam/KarmaKit&Date)
