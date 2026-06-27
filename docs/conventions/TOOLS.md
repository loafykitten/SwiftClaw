# Model-Callable Tools & Inference Loop

- `Tool` protocol (`Services/Tools/Tool.swift`) — a model-callable capability.
- `ToolRegistry.shared` lists tools offered on every normal chat
  (`WebSearchTool`, `InvestigateTool`). **System-only tools** (e.g.
  `EmailReviewNotifyTool`) must NOT be registered there — construct a scoped
  `ToolRegistry(tools:)` at the call site so the assistant can't invoke them
  during user chats.
- `InferenceService.shared.complete(messages:model:tools:systemPromptMode:)`
  runs an 8-round agentic tool loop. Use `.standalone` for system-work prompts
  (no persona); `.prependPersona` (default) for user chats.
- Long-running status is surfaced via `@MainActor @Observable` monitors
  (`ToolActivityMonitor`, `MailSyncMonitor`).
