# TextEcho UX Polish Plan

> **Phases 1–3 shipped (2026-03-20) via PRs #7–#9.** Phase 4 items not started.

**Branch:** `feature/ux-polish`
**Base:** `main` (after WhisperKit merge)
**Goal:** Make TextEcho feel polished for first-time setup and daily use without breaking the working audio/transcription/pedal stack.

**Rule:** NO changes to AudioRecorder, WhisperKitTranscriber, or the recording/transcription flow. All changes are UI, config, and device detection only.

---

## Phase 1: Config & Settings Stability (Low risk)

The `pedal_enabled` keeps resetting because the Settings UI doesn't expose it, and the config file gets recreated on clean installs with defaults. Fix these root causes.

### 1.1 Add pedal controls to Settings UI
- **File:** `SettingsWindow.swift`
- Add "Stream Deck Pedal" section below Audio:
  - Toggle: "Enable Stream Deck Pedal"
  - Picker: "Push-to-talk pedal" (Left / Center / Right) — default Center
  - Status indicator: "Connected" / "Not detected"
  - Note: "Quit Elgato Stream Deck app if pedal is not detected"
- Wire `pedalEnabled` and `pedalPosition` into the `save()` closure
- **Test:** Toggle pedal on/off in Settings, restart app, confirm it persists

### 1.2 Migrate whisper_model in config on load
- **File:** `AppConfig.swift`
- In `load()`, after reading `whisper_model`, run it through `WhisperKitTranscriber.migrateModelName()` so old configs with `"large-v3-turbo"` auto-fix to `"openai_whisper-large-v3_turbo"`
- **Test:** Set `whisper_model` to `"large-v3-turbo"` in config, launch app, confirm it loads correctly

### 1.3 Config file safety
- **File:** `AppConfig.swift`
- The `save()` method already merges with existing JSON (line 122-126) — this is correct. No change needed unless we find a bug.
- Verify: if the config file doesn't exist, `save()` creates it with all current values. ✓

---

## Phase 2: Pedal Auto-Detect (Medium risk — IOKit only, no audio)

Eliminate the need to unplug/replug the pedal after launching.

### 2.1 Add periodic device re-scan
- **File:** `StreamDeckPedalMonitor.swift`
- After `IOHIDManagerOpen`, if no device is immediately matched, start a 3-second repeating timer
- On each tick: call `IOHIDManagerSetDeviceMatching` again to re-trigger matching
- Cancel the timer once a device connects (in `deviceConnected`)
- Also cancel on `stop()`
- **Why this works:** The USB device may not present its HID interface immediately (especially if Elgato software was just quit). Re-triggering matching forces IOKit to re-scan.
- **Test:** Launch TextEcho, then plug in pedal — should auto-detect within 3 seconds without restart

### 2.2 Add reconnection after disconnect
- **File:** `StreamDeckPedalMonitor.swift`
- In `deviceDisconnected()`, restart the periodic re-scan timer
- When pedal is unplugged and replugged, it should reconnect automatically
- **Test:** Unplug pedal, wait 5 seconds, replug — should reconnect without app restart

---

## Phase 3: Setup Wizard Redesign (UI only)

Replace the current wizard with a proper multi-step walkthrough. All UI — no changes to recording, transcription, or audio.

### 3.1 New wizard flow
- **File:** `SetupWizard.swift` (rewrite view, keep controller)
- Steps:

```
Step 1: Welcome
  "Welcome to TextEcho"
  "Voice-to-text dictation that runs entirely on your Mac."
  "Let's set you up in a few quick steps."
  [Get Started →]

Step 2: Accessibility Permission
  Icon + explanation
  Status badge (Granted / Missing)
  [Open System Settings] button
  Auto-advances when granted (existing polling timer)

Step 3: Microphone Permission
  Icon + explanation
  Status badge
  [Open System Settings] button
  Auto-advances when granted

Step 4: Transcription Model
  Model picker cards (existing, keep as-is)
  Download progress
  Error display (existing)

Step 5: Pedal Setup (NEW — optional)
  "Do you have an Elgato Stream Deck Pedal?"
  [Yes, set it up] → shows detection status, waits for connection
  [No, skip] → proceeds
  If detected: "Pedal connected! Center = push-to-talk, Left = paste, Right = enter"
  Sets pedal_enabled = true in config

Step 6: Ready
  Summary of what's configured
  "Hold middle-click or press the center pedal to dictate"
  [Start Using TextEcho]
```

### 3.2 Progress indicator
- Add step dots / progress bar at top of wizard (1 of 6, 2 of 6, etc.)
- Back button on steps 2+ (except can't go back from downloading model)

### 3.3 Restart helper
- If accessibility permission was just granted, show note: "TextEcho may need to restart for permissions to take effect"
- Add [Restart TextEcho] button that relaunches the app (reuse existing `restartApp()` from SettingsWindow)

---

## Phase 4: Quality of Life (Low risk)

### 4.1 Menu bar quick status
- Show pedal connection status in menu bar dropdown (if pedal is enabled)
- "Stream Deck Pedal: Connected ✓" or "Stream Deck Pedal: Not detected"

### 4.2 First-launch auto-enable pedal
- If Stream Deck Pedal is detected during first launch (before wizard), auto-set `pedal_enabled = true`
- User can still disable in Settings

### 4.3 Accessibility re-grant notification
- After rebuild/re-sign, if accessibility check fails on launch, show a macOS notification: "TextEcho needs Accessibility permission re-granted"
- Link to System Settings

---

## Implementation Order

| Step | What | Risk | Est. |
|------|------|------|------|
| 1.1 | Pedal in Settings UI | Low | 20 min |
| 1.2 | Model name migration | Low | 5 min |
| 2.1 | Pedal auto-detect timer | Medium | 15 min |
| 2.2 | Pedal reconnection | Low | 5 min |
| 3.1 | Wizard redesign | Low (UI only) | 45 min |
| 3.2 | Progress indicator | Low | 10 min |
| 3.3 | Restart helper | Low | 5 min |
| 4.1 | Menu bar pedal status | Low | 10 min |
| 4.2 | Auto-enable pedal | Low | 5 min |
| 4.3 | AX re-grant notification | Low | 10 min |

**Total:** ~2 hours

## Testing Gates

After each phase, verify:
- [ ] Mouse middle-click dictation still works (multiple recordings)
- [ ] Pedal center push-to-talk still works
- [ ] Pedal left (paste) and right (enter) still work
- [ ] App launches without crash
- [ ] Config persists across restart

---

## Files Modified (Expected)

| File | Phase | What changes |
|------|-------|-------------|
| `SettingsWindow.swift` | 1.1 | Add pedal section |
| `AppConfig.swift` | 1.2 | Model name migration on load |
| `StreamDeckPedalMonitor.swift` | 2.1, 2.2 | Auto-detect timer, reconnection |
| `SetupWizard.swift` | 3.1, 3.2, 3.3 | Full redesign |
| `TextEchoApp.swift` | 4.1 | Menu bar pedal status |
| `AppState.swift` | 4.2 | Auto-enable pedal on detect |

## Files NOT Modified (Protected)

| File | Why |
|------|-----|
| `AudioRecorder.swift` | Working audio capture — don't touch |
| `WhisperKitTranscriber.swift` | Working transcription — don't touch |
| `Transcriber.swift` | Protocol — stable |
| `InputMonitor.swift` | Working hotkey detection — don't touch |
| `TextInjector.swift` | Working text injection — don't touch |
