# Changelog

## 0.3.0 - Unreleased

- Renamed the Apple utilities helper from `openAICompatible(...)` to
  `chatCompletions(...)` and removed the OpenAI-specific type alias. The helper
  is a generic Chat Completions protocol client, not an official OpenAI SDK.

## 0.2.0 - 2026-06-23

- Rebuilt CoreAgent on native Xcode 27 Foundation Models types.
- Added persistent `CoreAgentSession` text, structured, schema, and streaming
  response APIs.
- Added a dynamic-profile factory path with history-only restore and explicit
  checkpoint compatibility revisions.
- Added best-effort lifecycle auditing and an explicit audit-boundary event for
  profile-owned tools, including later failures that revert the transcript.
- Added governed native tools with approval, allowlist, trusted-manifest,
  timeout, and total-call-budget policies.
- Added versioned transcript checkpoints with restore-time toolset validation.
- Added fail-fast disk checks for custom segments and typed metadata that cannot
  round-trip with concrete Swift type identity.
- Added ordered run events, bounded per-observer delivery, usage, and
  tamper-evident receipts.
- Added `RecordedLanguageModel` for deterministic, zero-network tests.
- Added optional Apple utilities, Claude, and Gemini provider Traits.
- Added session plugins with bounded pre-run context, post-run capture hooks,
  governed plugin tools, and transcript sanitization across retries and streams.
- Added the optional `CoreAgentMemory` product with scoped canonical SQLite
  records, FTS5 retrieval, provenance, supersession, tombstones, and Apple file
  protection defaults.
- Added automatic episode capture, durable three-attempt consolidation jobs,
  pending semantic candidates, approval policies, and a fresh-session
  Foundation Models consolidator.
- Added bounded untrusted-evidence injection, the governed
  `coreagent_search_memory` tool, disclosure filtering, optional index repair,
  deterministic Markdown export, and hard-purge cleanup.
- Suppressed retries after tool invocation (including authorization) and
  applied timeout/retry semantics to streaming before its first partial
  response.
- Removed the 0.1 provider/message/tool abstraction, adapter, tools product, and
  CLI.
