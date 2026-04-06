# LLM Review Mode — Plan

**Audience:** Developer (Braxton / Lochie)
**Purpose:** Design and implementation plan for "review before paste" mode in LLM dictation flow.

---

## Current Flow Analysis

### The LLM pipeline (AppState.swift `handleLLM`)

1. Transcription completes → `handleLLM(text:)` called on `@MainActor`
2. `overlay.showProcessing(isLLM: true)` — shows purple scanner bar
3. `llmProcessor.generate(...)` called with streaming token callback
4. **During generation:** each partial token batch calls `overlay.showResult(partialText, isLLM: true)` — overlay flickers through partial text live
5. **On completion:** `overlay.showResult(response, isLLM: true)` — final text shown
6. If `config.model.llmAutoPaste == true` → `textInjector.inject(response)` fires immediately
7. `TranscriptionHistory.shared.add(text: response, isLLM: true)`

### The overlay (Overlay.swift)

The overlay currently has these states in `OverlayState`:

- `.hidden`, `.recording`, `.streamingPartial(text:)`, `.processing`, `.loadingModel`, `.downloading`, `.result(isLLM: Bool)`, `.error`

The `.result(isLLM: true)` state uses `theme.processing` (purple) as its accent colour and auto-hides after `min(1.5 + Double(text.count) / 100.0, 4.0)` seconds (1.5–4s depending on length).

`OverlayWindowController.showResult()` schedules an `autoHide` timer immediately on show. There is no mechanism to block that timer or wait for user input.

The window is created with `ignoresMouseEvents = true` — it absorbs no clicks at all today.

### TextInjector

`inject(_:)` puts text on the pasteboard and fires `Cmd+V`. No delay, no review step.

### Config

`llmAutoPaste: Bool` (default `true`). When `false`, the response is shown in the overlay but the auto-hide timer still fires and the text disappears. The flag exists but the "display only" path provides no way to paste — it is effectively a discard path.

### InputMonitor / hotkeys

The event tap intercepts all keyboard events including ESC (keyCode 53). There is no "confirm" hotkey today, but the infrastructure exists to add one. The tap runs on a dedicated background thread; all events dispatch to `@MainActor` via `DispatchQueue.main.async`.

### Key constraint: no mouse interaction

The overlay window is `ignoresMouseEvents = true`. Any click-to-paste design requires changing this for the review state only, or using an NSEvent local monitor instead of the CGEventTap.

---

## Proposed UX Design

### Guiding principles

- Keep it minimal — don't add UI chrome that distracts from the text
- Stay keyboard-first — LLM users are already holding modifier keys
- Match the existing overlay aesthetic — no new windows, no dialogs
- Default to safe — if the user walks away, the overlay should dismiss and discard rather than paste unexpectedly

### Recommended interaction model: Enter to paste, ESC to discard

When generation is complete, the overlay transitions to a `.llmReview` state. The text is shown with an amber accent (distinct from the green "done" and purple "processing" colours). A small hint line below the text reads:

```
↵ paste  ·  ESC dismiss
```

The user presses **Return/Enter** to inject the text or **ESC** to discard it. The overlay then hides.

If neither key is pressed within **15 seconds**, the overlay auto-dismisses without pasting (safe default).

Why Enter rather than the original trigger hotkey (Shift+Middle-click / Ctrl+Shift+D)?

- Enter is unambiguous — it will not conflict with any active application unless a text field is focused, and in that context the user probably wants to paste into it anyway
- Re-triggering the LLM hotkey to confirm would create confusion about whether it starts a new recording
- Enter already exists in TextInjector as `sendEnter()` — it is already intercepted conceptually
- Most users will understand "press Enter to confirm" without a tutorial

Why not click-to-paste?

- Requires enabling mouse events on the overlay window for a specific state, then disabling again — manageable but adds complexity and risks accidental pastes if the user moves the cursor near the overlay
- Enter is faster and doesn't require moving hands to the mouse

### Overlay hint design

The hint text should be subtle — secondary opacity, small monospaced font, below the result text:

```
↵ paste  ·  ESC dismiss
```

It should only appear in `.llmReview` state, not in `.result(isLLM: false)` (normal transcription). The accent colour for `.llmReview` is amber (`theme.loading` — `#FFC200`) rather than purple, clearly distinguishing it from the streaming partial state and the auto-paste result state.

### Streaming partials during generation

The partial token callback continues to call `overlay.showResult(partialText, isLLM: true)` during generation. This is fine — the hint text only appears after `generate()` completes and the state transitions to `.llmReview`. During streaming, the state remains `.result(isLLM: true)` (unchanged from today). The transition to `.llmReview` is a single state change after the final response arrives.

No change to the streaming token display path is needed.

### Config approach

**Extend `llmAutoPaste`, do not replace it.** The existing flag maps cleanly:

| `llmAutoPaste`   | Behaviour                                                           |
| ---------------- | ------------------------------------------------------------------- |
| `true` (default) | Existing behaviour — paste immediately when generation completes    |
| `false`          | New behaviour — enter `.llmReview` state, wait for Enter or timeout |

This is the least disruptive change: users who already set `llmAutoPaste = false` (display-only) will get the improved "reviewable" experience automatically. No new config key is required, and Settings UI only needs a label change from "Auto-paste LLM result" to something like "Auto-paste LLM result (off = review before paste)".

---

## Implementation Plan

### Files to change

| File                 | Change                                                                                                                                                                                                                                                                       |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Overlay.swift`      | Add `.llmReview` state; add hint text in `OverlayView`; update `accentColor`, `resultTextColor`, `statusIndicator` for new state; add `showLLMReview(_:)` on `OverlayViewModel` and `OverlayWindowController`                                                                |
| `AppState.swift`     | In `handleLLM`, after `generate()` completes: if `!llmAutoPaste` call `overlay.showLLMReview(response)` instead of `overlay.showResult(response, isLLM: true)`; store `pendingLLMResponse` for injection on confirm; add `confirmLLMPaste()` and `discardLLMPaste()` methods |
| `InputMonitor.swift` | Add `InputEvent.confirmPaste` case; in `handleKeyDown`, when keyCode == 36 (Return) and `dictationActive == false`, emit `.confirmPaste` — but only when AppState is in review mode (pass a flag or query state; see design note below)                                      |
| `AppConfig.swift`    | No structural change; update the comment on `llmAutoPaste` to reflect new semantics                                                                                                                                                                                          |

### Design note: scoping the Enter intercept

The CGEventTap captures all system keyboard events. Emitting `.confirmPaste` on every Return keypress would break Return in all other apps whenever the overlay is not visible. Two options:

**Option A — Guard in InputMonitor with a shared flag.** `AppState` sets a `isAwaitingLLMConfirm: Bool` property (main thread). `InputMonitor` checks this flag before emitting `.confirmPaste`. Because `AppState` is `@MainActor` and `InputMonitor` callbacks dispatch to main, a simple `@MainActor` property with a `Task { @MainActor }` read works without locks.

**Option B — Use an NSEvent local monitor instead of the CGEventTap for the confirm key.** Install a temporary `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` when entering review mode, remove it when leaving. Local monitors only fire when TextEcho's process is active, which is wrong — the user is typing in another app when the overlay is shown.

**Option A is correct.** The guard flag approach keeps the intercept scoped and is consistent with how the ESC case is already handled (ESC is always intercepted but only acts when `isRecording == true`).

The Return keypress should be consumed (not passed through) when it triggers paste confirmation — otherwise it sends an Enter keystroke to whatever app is in focus, which could submit a form or insert a newline. Return `nil` from the CGEventTap callback for that event.

The ESC key is already intercepted and calls `cancelRecording()`. Extend `cancelRecording()` or add a separate branch: if `isAwaitingLLMConfirm`, call `discardLLMPaste()` instead.

### Detailed step-by-step

**Step 1 — Add `OverlayState.llmReview` (Overlay.swift)**

Add a new case to `OverlayState`:

```swift
case llmReview
```

Update the `==` implementation to include `.llmReview`.

Add `showLLMReview` to `OverlayViewModel`:

```swift
func showLLMReview(_ text: String) {
    state = .llmReview
    statusText = "LLM READY"
    resultText = text
}
```

**Step 2 — Add hint text in `OverlayView.body` (Overlay.swift)**

In the result text block, add a conditional hint below `resultText`:

```swift
if case .llmReview = viewModel.state {
    Text("↵ paste  ·  ESC dismiss")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(theme.loading.opacity(0.5))
        .tracking(0.8)
        .transition(.opacity)
}
```

**Step 3 — Update accent and indicator colors (Overlay.swift)**

In `accentColor`:

```swift
case .llmReview: return theme.loading  // amber
```

In `resultTextColor`:

```swift
case .llmReview: return theme.loading.opacity(0.9)
```

In `statusIndicator` (add a case before `.error`):

```swift
case .llmReview:
    Circle()
        .fill(CyberColors.amber)
        .frame(width: 8, height: 8)
        .scaleEffect(pulseScale)  // pulse to indicate "waiting"
        .shadow(color: CyberColors.amber.opacity(0.6), radius: 4)
```

**Step 4 — Add `showLLMReview` to `OverlayWindowController` (Overlay.swift)**

```swift
func showLLMReview(_ text: String) {
    DispatchQueue.main.async {
        self.viewModel.showLLMReview(text)
        self.show()
        self.autoHide(after: 15.0)  // safe discard timeout
    }
}
```

**Step 5 — Add `InputEvent.confirmPaste` (InputMonitor.swift)**

```swift
case confirmPaste
```

In `handleKeyDown`, at the top of the function (before the escape check, or alongside it):

```swift
if keyCode == 36 { // Return
    _onEvent?(.confirmPaste)
    // Do NOT return here — let AppState decide whether to consume
}
```

Modify the event tap callback to conditionally suppress the Return event. Because the callback receives the event reference, we can return `nil` to consume it. The cleanest approach: `InputMonitor` exposes a `var shouldConsumeReturn: Bool = false` property. The tap callback returns `nil` when `shouldConsumeReturn && keyCode == 36`.

**Step 6 — Add review state to `AppState` (AppState.swift)**

```swift
private var isAwaitingLLMConfirm = false
private var pendingLLMResponse: String = ""
```

Modify `handleLLM` completion block:

```swift
await MainActor.run {
    self.overlay.showResult(response, isLLM: true)  // show final text (streaming done)
    if self.config.model.llmAutoPaste {
        self.textInjector.inject(response)
    } else {
        self.pendingLLMResponse = response
        self.isAwaitingLLMConfirm = true
        self.inputMonitor.shouldConsumeReturn = true
        self.overlay.showLLMReview(response)
    }
    TranscriptionHistory.shared.add(text: response, isLLM: true)
}
```

Add confirm/discard methods:

```swift
func confirmLLMPaste() {
    guard isAwaitingLLMConfirm else { return }
    isAwaitingLLMConfirm = false
    inputMonitor.shouldConsumeReturn = false
    let response = pendingLLMResponse
    pendingLLMResponse = ""
    textInjector.inject(response)
    overlay.hide()
}

func discardLLMPaste() {
    guard isAwaitingLLMConfirm else { return }
    isAwaitingLLMConfirm = false
    inputMonitor.shouldConsumeReturn = false
    pendingLLMResponse = ""
    overlay.hide()
}
```

Update `handleInputEvent` in the `.escape` case:

```swift
case .escape:
    if isAwaitingLLMConfirm {
        discardLLMPaste()
    } else {
        cancelRecording()
    }
case .confirmPaste:
    confirmLLMPaste()
```

**Step 7 — Settings label update (SettingsWindow.swift)**

Find the `llmAutoPaste` toggle label and update it:

```
"Auto-paste LLM result"  →  "Auto-paste (off = review before paste)"
```

No structural settings change needed.

---

## Risks and Tradeoffs

**Return key intercept scope.** The CGEventTap fires for every Return keypress system-wide. The `shouldConsumeReturn` guard prevents false triggers, but if `isAwaitingLLMConfirm` is somehow stuck `true` (e.g. crash during generation), Return would be consumed and suppressed globally. Mitigation: add a watchdog — if the review state persists for more than 30 seconds, auto-discard and reset the flag.

**Auto-hide timer vs. user action.** The 15-second timeout auto-dismisses without pasting. The `OverlayWindowController.autoHide` uses a `DispatchWorkItem`; if the user presses Enter before the timer fires, `overlay.hide()` is called which calls `cancelAutoHide()` — this is already wired correctly in the existing `hide()` implementation. No race condition.

**History timing.** Currently `TranscriptionHistory.shared.add(text: response, isLLM: true)` fires regardless of whether the user actually pastes. In review mode, should history only log on paste, or always? The plan logs it immediately on generation completion (before the user decides) for consistency with how standard transcription history works — the history records what was transcribed/generated, not what was pasted. This is the simpler approach and avoids a refactor of history logic.

**Streaming partials during generation.** The partial callback calls `showResult(partialText, isLLM: true)` which keeps the state as `.result(isLLM: true)` during streaming. The transition to `.llmReview` only happens after the final `generate()` call returns — the streaming path is unaffected.

**`llmAutoPaste = false` existing users.** Currently `false` means "show in overlay, no paste" — the response is visible for 1.5–4s then disappears. These users get an upgrade: the overlay now stays for 15 seconds and allows a paste confirmation. This is strictly better behaviour and requires no migration.

**Keyboard shortcut conflict.** If the user is filling in a form in another app while the overlay is visible (e.g. they triggered LLM from a web form), pressing Enter to submit the form would be consumed by TextEcho instead. This is the primary UX risk. Mitigation: keep the timeout short (15s), and document the behaviour clearly. A future improvement could detect whether the frontmost app has a focused text field and disable the intercept, but that requires AX APIs and is out of scope for this iteration.

---

## Complexity Estimate

**Low-medium.** No new dependencies, no new windows, no async architecture changes. The core work is:

- ~20 lines in `Overlay.swift` (new state case, hint text, color branches)
- ~30 lines in `AppState.swift` (new state vars, confirm/discard methods, handleInputEvent branch)
- ~10 lines in `InputMonitor.swift` (new event case, return-consume flag, handleKeyDown branch)
- ~5 lines in `SettingsWindow.swift` (label copy)

Total: ~65 lines of Swift across 4 files. No new files needed. The change is self-contained and fully backward compatible (existing `llmAutoPaste = true` users see no change).

**Testing surface:** Manual test matrix covers (a) autoPaste=true still works, (b) autoPaste=false shows review state, (c) Enter pastes, (d) ESC discards, (e) 15s timeout discards, (f) Enter is not consumed when review state is inactive, (g) generation error path still shows error overlay.

**Estimated dev time:** 1–2 hours including testing.

---

## Verification

Before marking this complete, verify:

- [ ] `llmAutoPaste = true` — generation completes, result pastes immediately, overlay auto-hides as before
- [ ] `llmAutoPaste = false` — generation completes, overlay shows amber hint "↵ paste · ESC dismiss" with 15s countdown
- [ ] Enter keypress with overlay in `.llmReview` — text injected into frontmost app, overlay hides
- [ ] ESC keypress with overlay in `.llmReview` — overlay hides, nothing pasted
- [ ] 15-second timeout — overlay auto-hides, nothing pasted, `isAwaitingLLMConfirm` reset to false
- [ ] Enter keypresses when NOT in review mode pass through normally to other apps
- [ ] Partial token streaming still shows purple text updates during generation (unchanged)
- [ ] History entry created in both paste and discard paths
- [ ] Settings label updated and describes behaviour correctly
