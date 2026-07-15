# Model-Callable Tools & Inference Loop

- `Tool` protocol (`Services/Tools/Tool.swift`) — a model-callable capability.
- `ToolRegistry.shared` lists tools eligible for normal chats: web search,
  investigation, and the Notes read tools. `availableTools` applies setup,
  enablement, and per-message opt-in gates before each call.
- **System-only tools** (such as review fetch/notify tools) must NOT be
  registered on `ToolRegistry.shared`. Construct a scoped
  `ToolRegistry(tools:)` at the call site so user chats cannot invoke them.
- Request-bound tools that need live state, such as Notes edit proposals, are
  appended at the chat call site instead of stored in the shared registry.
- `InferenceService.shared.complete(..., systemPromptMode:tools:)`
  runs an 8-round agentic tool loop. Use `.standalone` for system-work prompts
  (no persona); `.prependPersona` (default) for user chats.
- Long-running status is surfaced via `@MainActor @Observable` monitors
  (`ToolActivityMonitor`, `MailSyncMonitor`).
