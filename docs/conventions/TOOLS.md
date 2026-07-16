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
- A proposal tool creates durable proposed state and a review card; it does not
  perform the mutation. Approval goes through a feature dispatcher that binds
  the originating store/vault, re-reads current state, checks the captured
  version/hash, snapshots before mutation, and uses the feature repository.
  Reject changes proposal state only. A stale target must become visibly
  conflicted, never be overwritten. Notes is the reference implementation
  (`NoteEditProposal`, `NoteProposalDispatcher`, `DiffEngine`).
- Long-lived file/store operations that can overlap a settings reset or source
  switch hold a feature-scoped lease for their full read/check/write sequence.
  Teardown blocks new leases and drains existing ones before replacing state.
- `InferenceService.shared.complete(..., systemPromptMode:tools:)`
  runs an 8-round agentic tool loop. Use `.standalone` for system-work prompts
  (no persona); `.prependPersona` (default) for user chats.
- Long-running status is surfaced via `@MainActor @Observable` monitors
  (`ToolActivityMonitor`, `MailSyncMonitor`).

Keep shared registries capability-based, not convenience-based: normal chat
gets user-invoked tools only; schedulers/review services get the smallest scoped
registry they need; request-bound approval tools exist only for that request.
