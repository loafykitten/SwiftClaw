# Local User Notifications

## Context

SwiftClaw currently signals background activity only through the dock badge (unread chats, owned by `AppRouter`) and in-app sidebar dots. Nothing reaches the user when the app is hidden or in another Space: a finished chat reply, a scheduled inbox review, or new mail all land silently. This plan adds local OS notifications via `UNUserNotificationCenter` — no backend, no push/APNs — behind an opt-in Settings toggle, built around a reusable service/factory so future features (Reminders, Calendar, DeepResearch — all stubs today) can post notifications through the same API.

**Confirmed decisions:** all three triggers in v1 (new inbox mail, review results, chat replies); mail notifications get quick actions (Archive/Delete/Flag, inline Reply as a separable phase); tapping navigates to the email/chat; authorization is requested when the user first enables the Settings toggle, not at launch.

**No service registration needed:** local notifications require no entitlement, no capability, no APNs. The app is already signed (Automatic, team FK3F29BFNM) and sandboxed — that's sufficient. Only caveat: must run via the signed Xcode target; unsigned `swift run` builds silently fail authorization.

## Architecture

New directory `SwiftClaw/Services/Notifications/`, following the house singleton convention (`@MainActor @Observable final class` + `static let shared`, like `AppRouter`/`EmailWorkflowManager`).

```swift
// NotificationScheduling.swift — testability boundary.
// UNUserNotificationCenter.current() crashes in test processes (no app bundle),
// so the real center is wrapped LAZILY and tests inject a spy.
@MainActor protocol NotificationScheduling: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func authorizationStatus() async -> UNAuthorizationStatus
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers: [String])
}

// AppNotificationService.swift — the facade every feature calls.
@MainActor @Observable final class AppNotificationService {
    static let shared: AppNotificationService
    private(set) var authorizationStatus: UNAuthorizationStatus  // drives Settings UI

    func activate()                                   // delegate + categories; SwiftClawApp.init
    @discardableResult func enableNotifications() async -> Bool  // toggle-on path; [.alert, .sound], NO .badge
    func refreshAuthorizationStatus() async

    // Posting API — each checks master + per-source toggle + auth, then adds a request.
    func notifyChatReply(chatID: UUID, chatTitle: String, preview: String)
    func notifyReviewResult(chatID: UUID, summary: String)
    func notifyNewMail(_ messages: [NewMailNotificationInfo])   // digest logic lives here

    // Cleanup when the user reads the thing in-app.
    func removeDeliveredChatNotifications(chatID: UUID)
    func removeDeliveredEmailNotification(emailID: UUID)
}
```

Deterministic identifiers double as dedupe/replacement and removal keys: `chatreply.<chatID>`, `review.<chatID>`, `mail.<emailID>`, `mail.digest.<accountID>`. Thread identifiers group by chat / mail account. `userInfo` carries a small codable routing payload (`kind` + target UUID string).

**Dock badge stays with `AppRouter`** — never set `.badge` on notification content, never request `.badge` authorization.

**Delegate:** `AppNotificationService` conforms to `UNUserNotificationCenterDelegate`, installed in a new `SwiftClawApp.init` (preview-guarded) so tap-launched notifications are caught before launch completes — no `NSApplicationDelegateAdaptor` needed (fallback if manual testing shows tap-launches drop: add a minimal adaptor). Swift 6 note: delegate methods are `nonisolated` and UN types aren't Sendable — extract identifier/action/payload/userText **before** hopping to `@MainActor`.

- `willPresent`: show `[.banner, .list, .sound]` even when frontmost, EXCEPT suppress when the user is viewing the target (that chat via `AppRouter.isViewingChat`; coarse v1 for mail: workspace selected).
- `didReceive`: `chatReply`/`review` → `AppRouter.shared.selectChat(_:)` (AppRouter.swift:70); `newMail` → `AppRouter.shared.showEmail(_:)` (AppRouter.swift:76); digest → select workspace. Router-only, safe on cold launch.

## Phase 1 — Core service, settings, authorization

Create:
- `Services/Notifications/NotificationScheduling.swift` — protocol + lazy `SystemNotificationCenter` wrapper.
- `Services/Notifications/AppNotificationService.swift` — facade, `LocalizedError` enum, `os.Logger` category "notifications", DEBUG `configureForTesting(center:userDefaults:)`/`resetForTesting()` mirroring `EmailWorkflowManager`.
- `Services/Notifications/NotificationRoutingPayload.swift` — payload + identifier/category constants.
- `Settings/Sections/NotificationSettingsView.swift` — master toggle (on-enable runs `enableNotifications()`); denied-state warning row + "Open System Settings" button (`#if os(macOS)`, `x-apple.systempreferences:com.apple.Notifications-Settings.extension`); three per-source toggles disabled when master off; refresh status on appear/scene-active.

Modify:
- `Settings/AppSettings.swift` — keys `settings.notifications.enabled` (default **false**), `.newMail.enabled` / `.reviewResults.enabled` / `.chatReplies.enabled` (default true, gated on master), plus `SettingsStorage` helpers with injectable `userDefaults` per docs/conventions/SETTINGS.md.
- `Settings/SettingsView.swift` — new `SettingsSection.notifications` case ("Notifications", `bell.badge`, always visible — sources span Chats + Email, so no single feature section fits).
- `Settings/EmailSettingsView.swift:288` — rename the existing "Notifications" section (auto-navigate toggle) to "Review Chat" to avoid a name clash.
- `SwiftClawApp.swift` — add `init()` calling `AppNotificationService.shared.activate()` (skip in previews). New files need no pbxproj edits (file-system-synchronized groups).

## Phase 2 — Delegate routing + chat-reply + review triggers

- `Shared/AppRouter.swift` — make `isViewingChat(_:)` (line 137) internal; in `clearUnreadMessages(in:)` call `removeDeliveredChatNotifications(chatID:)` (covers chat and review-chat opens; not-activated no-op keeps existing tests inert).
- `Features/Chats/ChatCompletionService.swift:127` — next to `noteNewChatMessages`, if `!AppRouter.shared.isViewingChat(chat.id)`, call `notifyChatReply(...)` with a ~150-char preview of `response`.
- Review summary threading: extend `EmailReviewNotifyTool.onReviewCreated` to pass the model's summary string → `EmailReviewService` → `EmailWorkflowManager.handleReviewChatCreated(chatID:summary:)` (~line 296), which calls `notifyReviewResult(...)` after posting `.emailReviewChatCreated`. `willPresent` suppression is the second safety layer against auto-navigate double-surfacing.

## Phase 3 — New-mail trigger + quick actions (Archive/Delete/Flag)

Repository/worker refactor (the sync currently surfaces only a scalar count aggregated across ALL folders including Sent/Junk):
- `Services/Email/Repository/EmailRepository.swift:29` — `upsertMessages` returns `EmailUpsertOutcome { insertedCount, inserted: [InsertedEmailSummary] }` (id, fromDisplay, subject, snippet, isRead), populated in the `insert` branch (~line 745). Callers are few — mechanical `.insertedCount` fixes.
- `Services/Email/Sync/MailSyncWorker.swift` — anti-spam guard from existing flags: `suppressNotifications = !didHavePriorState || didReset` (lines 248/267 — first sync of an account and UIDVALIDITY rebuilds emit nothing). Collect `NewMailNotificationInfo` only for `role == .inbox && !isRead && !suppress`; inject `newMailNotifier: @Sendable ([NewMailNotificationInfo]) async -> Void` (pattern: existing `syncStateProvider`) defaulting to the shared service; call after `MailSyncMonitor.recordCompleted`. Keep `syncOnce() -> Int` contract.
- Digest policy in `notifyNewMail`: per account per pass, 1–4 → individual notifications with actions; ≥5 → one digest ("N new messages", replaces prior digest, no actions). Thresholds as named constants, tuned after live testing.

Quick actions:
- Register `UNNotificationCategory("newMail")` in `activate()`: `mail.archive`, `mail.delete` (`.destructive`), `mail.flag`.
- Create `Services/Notifications/NotificationMailActionHandler.swift` — `@MainActor`, `configure(modelContainer:)` from `AppBootstrap.run()`; queues responses arriving before configuration (cold-launch action tap), drains on configure. Dispatch: fetch `Email` by ID, resolve account → `SwiftMailClient`, reuse `EmailServerAction.archive/delete/setFlags` (Services/Email/EmailServerAction.swift) verbatim. Missing email/account → logged no-op. Client factory injectable.
- `Features/Email/EmailThreadDetailView.swift` mark-read path — call `removeDeliveredEmailNotification(emailID:)`.

## Phase 4 — Inline Reply (separable; cut without touching 1–3)

- Create `Services/Email/EmailReplySender.swift` — extract from `EmailReplyComposerView.send()` (EmailReplyComposerView.swift:103–149): reply-draft building (to/cc/subject/quote) + send (Message-ID, `OutgoingEmail` with `inReplyTo`/`references`, `SwiftMailClient.send`, `upsertSentMessage`). Composer refactored to call it — behavior-neutral, verified against `EmailSentReconciliationTests`.
- Add `UNTextInputNotificationAction("mail.reply")` to the `newMail` category; handler extracts `userText` pre-hop, sends via `EmailReplySender`; on failure posts a fallback "Reply failed — open SwiftClaw to retry" notification.

## Tests (Swift Testing, `SwiftClawTests/Notifications/` + extensions)

- `AppNotificationServiceTests` — spy center: master/per-source gating, auth options exclude `.badge`, no-op before activation, digest thresholds, identifier/payload round-trip.
- Routing tests — payload decode → `AppRouter.resetForTesting()` state assertions; viewing-chat suppression.
- Extend `EmailRepositoryTests` (outcome matches inserted rows), `MailSyncWorkerIncrementalTests` (inbox-unread only; first sync / UIDVALIDITY reset / Sent-Junk roles emit nothing), `EmailReviewNotifyTool`/`EmailWorkflowManager` tests for the new callback arity.
- `NotificationMailActionHandlerTests` — in-memory container + spy `MailClient`: each action mutates locally and hits the server; pending-queue drain.
- Phase 4: `EmailReplySender` tests with spy client.

## Verification

1. `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build -derivedDataPath /tmp/DerivedData | xcbeautify --quiet` — Swift 6 strict concurrency is the gate.
2. Targeted test runs with `-only-testing:SwiftClawTests/<Suite>` per phase.
3. Live run via the Xcode target (signed) — see human checklist below.

## Human-only / manual live-testing checklist

Things only a human can do (permission dialogs and banner UX need someone at the machine):

1. **Authorization dialog** — enable the toggle in Settings, click Allow; repeat on a reset (`Don't Allow`) to verify the denied-state hint + "Open System Settings" button + status refresh on return.
2. **Banner style** — macOS defaults to transient Banners; action buttons hide behind hover/"Options". Consider switching SwiftClaw to "Alerts" in System Settings while testing actions.
3. **Trigger walkthrough** — chat reply while viewing another chat (banner) vs same chat (suppressed); scheduled review firing; send yourself an email for the new-mail path; fresh account first sync produces zero notifications.
4. **Actions against a real IMAP server** — Archive/Delete/Flag reflect server-side; inline Reply threads correctly at the recipient.
5. **Cold-launch tap** — quit the app, click a delivered notification, confirm it launches and navigates (this validates the `App.init` delegate-timing assumption; if it drops, we add the minimal `NSApplicationDelegateAdaptor` fallback).
6. **Focus/DND** — banners are swallowed silently under Focus; keep it off while testing.
7. Confirm the dock badge still reflects unread chats only.

## Risks

- **Swift 6 + non-Sendable UN types** — the "extract Sendable data before the actor hop" rule in delegate callbacks is the main friction point.
- **SPM `swift test` vs Xcode tests** — any code path touching `UNUserNotificationCenter.current()` unconditionally breaks bundle-less test runs; lazy wrapper + activation guard is the defense.
- **Delegate timing on tap-launch** — believed fine from `App.init`; verified by human step 5.
- **willPresent granularity for mail** — v1 suppresses per-workspace, not per-email (AppRouter doesn't track the open email); acceptable, refine later.
