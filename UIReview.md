# UI Review: Providers Settings View

## 1. Visual Hierarchy & Layout

### Inconsistent Row Alignment in Azure Deployment List
The `minus.circle.fill` button in existing rows sits inline with the **Display Name** field, while the `plus.circle.fill` for new rows sits below both fields. This creates a staggered, misaligned grid.

**Recommendation:** Use a consistent `HStack` layout for both existing and new rows. Alternatively, move the **Add** action to a bottom-aligned "+ Add Deployment" button to separate the creation UX from the list itself.

### Section Separation Is Muddy
Because this is macOS, `.grouped` `Form` sections render with very subtle backgrounds. Azure, Neuralwatt, and OpenRouter blend together when the view scrolls.

**Recommendation:** Add `.padding(.bottom)` to sections, or use a slightly stronger visual divider (e.g., a `Divider()`) between providers to create stronger visual "cards."

### Content Is Cut Off
The screenshot shows a scrollbar and the OpenRouter section is clearly truncated. The window's `minHeight: 520` might be too small for three expanded providers with deployments + models.

**Recommendation:** Either increase the default window height or consider making each provider section collapsible (`DisclosureGroup`), since users likely only configure one provider at a time.

---

## 2. Usability & Interaction

### No Way to Reveal the API Key
The `SecureField` is correct for shoulder-surfing protection, but there is no "show/hide" toggle. Users often paste a key and want to verify the last few characters.

**Recommendation:** Add an eye icon button next to each `SecureField` that toggles between `SecureField` and `TextField`.

### Destructive Delete Without Confirmation/Undo
The `minus.circle.fill` buttons remove deployments/models immediately. There is no undo gesture or confirmation.

**Recommendation:** While the existing `.help("Remove...")` tooltip is good, consider adding a brief deletion animation or a small "Removed — Undo" banner to prevent accidental data loss.

### "Display Name" Is Optional but Looks Required
In the Azure section, a blank Display Name falls back to the `deploymentName` in the picker. However, both "Deployment Name" and "Display Name" text fields carry equal visual weight, which may lead users to unnecessarily fill both.

**Recommendation:** De-emphasize Display Name (smaller font, placeholder text like "Optional display name") or hide it behind an "Advanced" toggle if most users don't need it.

---

## 3. Data Entry & Validation

### No Inline Validation
There is no feedback if an API key is empty, malformed, or if a deployment name is duplicated. For example, if a user leaves the Azure Resource Name blank, the app may fail later at runtime with a network error.

**Recommendation:** Add small red validation messages below required fields (e.g., "Resource Name is required to use Azure") to surface errors early.

### Model Names Are Plain Strings
For Neuralwatt and OpenRouter, models are just `[String]`. There is no autocomplete, validation against the actual provider's model list, or way to specify a display name vs. raw model ID.

**Recommendation:** Consider migrating to a richer model object (like `AzureDeployment`) in the future. For now, showing a small subtitle of the actual ID vs. a friendly name would help.

---

## 4. Accessibility & Polish

### Missing Labels for Icon-Only Buttons
The plus/minus buttons rely entirely on SF Symbols. While `.help()` is set, ensure buttons also have explicit `accessibilityLabel`s for VoiceOver users.

**Example:**
```swift
Button { ... } label: { Image(systemName: "minus.circle.fill") }
    .accessibilityLabel("Remove deployment")
```

### Form Title Redundancy
The window already has a navigation title (`"Providers"`), but the screenshot shows "Providers" centered in what appears to be a custom toolbar area. Verify the title isn't duplicated by both `.navigationTitle` and a manual `Text` somewhere.

### Focus Management
When adding a new deployment or model, focus isn't moved to the new text field automatically. After tapping `+`, users must click into the field.

**Recommendation:** Focus the new field programmatically via `@FocusState`.

---

## Summary of Recommended Changes

| Priority | Issue | Suggested Fix |
|---|---|---|
| **High** | OpenRouter section cut off | Increase default window height or use `DisclosureGroup` per provider |
| **High** | No API key visibility toggle | Add an eye icon to toggle `SecureField` ↔ `TextField` |
| **Medium** | Uneven Azure deployment row layout | Align buttons consistently or move "+ Add" to a separate button |
| **Medium** | No inline validation | Add small validation text under required fields |
| **Low** | Sections blend together | Add `Divider()` or extra padding between provider sections |
| **Low** | Accessibility | Add `.accessibilityLabel` to all icon-only buttons |

---

## Overall Assessment
The layout is clean and idiomatic for a macOS settings panel. The main issues are **vertical space management** (cut-off content) and **missing reveal toggles for secrets**. Addressing those two would have the biggest immediate impact on user experience.
