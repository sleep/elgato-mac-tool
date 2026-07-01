# Design: Keep the capture engine at Game-Mode-equivalent priority the whole time it's on

**Date:** 2026-07-01
**Status:** Approved (pending spec review)

## Problem / intent

The user asked to "force macOS Game Mode active while the app is on" to improve
performance. macOS provides **no supported API** for an app to switch system Game
Mode on for itself — it activates automatically only for apps categorized as games
while fullscreen and frontmost, and it *de-prioritizes* background apps. A capture
tool typically runs in the background alongside the game being played, so a "game"
identity would be counterproductive.

However, the *performance* half of Game Mode — elevated thread QoS plus App Nap /
timer-throttling suppression — is exposed through real APIs, and this codebase
**already uses them**:

- Capture, audio, and encoder queues run at `.userInteractive` QoS
  (`CaptureEngine.swift:96,144`, `HardwareEncoder.swift:188`) — already maxed.
- The full capture pipeline asserts an `NSProcessInfo` activity with
  `[.userInitiated, .latencyCritical, .idleSystemSleepDisabled]`
  (`CaptureEngine.swift:583`) — the same anti-throttling mechanism Game Mode uses.

**The gap:** that activity is created only in `start()` (full capture) and is
released in `stop()` even when `stop()` falls back to **preview-only** mode. So while
merely monitoring the live preview (not recording), the capture session runs with no
priority boost. The code's own comment warns that *"AVCaptureSession stops delivering
frames to non-frontmost apps"* without this activity — meaning preview-only feeds can
stall or drop frames the moment the app is backgrounded behind a fullscreen game.

Additionally, the replay-writer disk queues (`Recorder.swift:233-234`) use *default*
QoS, so replay saves can be throttled when the app is backgrounded — the exact moment
they matter.

## Goal

Hold the capture engine's priority boost for the **entire lifetime of a live session
— preview and full capture alike** — so backgrounding the app never causes the feed
or a replay save to be throttled. This is the supported-API equivalent of "Game Mode
on while the app is on."

Non-goals: system Game Mode toggling, app-category changes, a user-facing on/off
toggle (the boost is always on while a session is live, matching the "force it"
intent), any change to the already-maxed queue QoS in the capture path.

## Design

### Invariant

`captureActivity` is non-nil **if and only if** a session is live
(`isPreviewing || isRunning`).

### 1. Centralize the activity assertion into two idempotent helpers

Add to `CaptureEngine`:

```swift
/// Opt the process out of App Nap / timer throttling and system idle-sleep for the
/// full lifetime of a live capture session (preview or full capture). This is the
/// supported-API equivalent of macOS Game Mode's priority elevation, and is what
/// keeps AVCaptureSession delivering frames while the app is backgrounded behind a
/// fullscreen game. Idempotent.
private func beginCaptureActivityIfNeeded() {
    guard captureActivity == nil else { return }
    captureActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
        reason: "Elgato capture session active"
    )
}

private func endCaptureActivity() {
    if let activity = captureActivity {
        ProcessInfo.processInfo.endActivity(activity)
        captureActivity = nil
    }
}
```

Sleep-disable (`.idleSystemSleepDisabled`) is held during preview too, per the user's
decision — the Mac stays awake while any live feed is shown.

### 2. Begin whenever a session goes live

- `startPreview()` — call `beginCaptureActivityIfNeeded()` after `isPreviewing = true`.
- `start()` — replace the inline `beginActivity` block (`CaptureEngine.swift:583-588`)
  with `beginCaptureActivityIfNeeded()`. When upgrading an existing preview in place,
  the guard keeps the already-held activity (no churn, seamless upgrade).

### 3. End only on true idle

- Remove the unconditional `endActivity` at the top of `stop()`
  (`CaptureEngine.swift:596-599`).
- In `stop()`'s fall-back-to-preview branch (`CaptureEngine.swift:614-617`): **keep**
  the activity — the session is still live.
- In `stop()`'s full-teardown `else` branch (`CaptureEngine.swift:618-621`): call
  `endCaptureActivity()`.
- `stopPreview()` — call `endCaptureActivity()` after teardown.

### 4. Elevate replay-writer queue QoS

In `Recorder.swift:233-234`, add `qos: .userInitiated` to the
`elgato.replay.write.video` and `elgato.replay.write.audio` queues so replay saves
aren't throttled while the app is backgrounded.

## Data flow (states)

```
no device ──startPreview──► preview (activity held) ──start──► capturing (activity held)
    ▲                            │  ▲                              │
    └────── stopPreview ─────────┘  └────────── stop (fallback) ───┘
        (activity released)              (activity kept — still preview)
```

Activity is released only on the transition back to "no device".

## Testing / verification

Manual (no unit-test harness for the capture engine in this repo):

1. Start preview only (don't record). Background the app behind a fullscreen app.
   Confirm the preview keeps updating (previously it could stall).
2. `log stream --predicate 'eventMessage CONTAINS "Elgato capture session active"'`
   or check `pmset -g assertions` shows a `PreventUserIdleSystemSleep` /
   latency-critical assertion held during preview *and* capture, and released only
   when the device is deselected.
3. Start capture, then stop (fall back to preview) — assertion stays held. Deselect
   device — assertion released.
4. Save a replay while backgrounded — completes promptly.

## Risk

Low. Changes are confined to `CaptureEngine` session lifecycle and two queue
declarations in `Recorder`. Main behavioral change is that the Mac will not
idle-sleep while a live preview is shown — intended, per the user's decision.
