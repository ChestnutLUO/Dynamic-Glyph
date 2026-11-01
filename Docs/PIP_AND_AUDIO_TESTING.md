# PiP size and music coexistence

The video canvas and inline source view default to a 10:1 aspect ratio
(640×64 at 2×; 4:1 at 384×96 before 2026-09-23). The
**Settings → Floating window → Shape and sharpness** controls let testers change
canvas width (256–640), height (64–192), and render resolution (1–3×). **Apply** saves the settings and
updates the active render loop; **Reset** restores 640×64 at 2×. Higher resolution
changes pixel density without changing the row's proportions. Removing
the inline view's fixed 120-point height avoids imposing a conflicting source
geometry. This is not proof that iOS will make the floating window 10:1: the
system controls its size, corners and touch interception. There is no public
size or position setter on `AVPictureInPictureController`. See
[covered-indicator recognition and PiP validation](COVERED_INDICATORS_AND_PIP.md)
for the fallback behavior, replay result, and sizing checks.

Use **Dynamic Island only** if even the smallest PiP covers the slot strip,
the drawing array, Done or Back. It disables PiP without stopping recognition.
Pinch and edge-tucking are system gestures; the app must not claim it can
shrink the system window below its minimum or make it pass touches through.

## Audio ownership

- Before presenting the capture picker, configure `.ambient` without calling
  `setActive(true)`. This avoids leaving Island-only capture at the default
  `soloAmbient`, which is non-mixing, while not claiming a playback category for
  a session that never plays anything: `.ambient` cannot interrupt another app
  by construction, whereas `.playback` only refrains while mixing holds.
  Whether the capture service uses this policy needs a device test; it may own
  a separate audio session.
- Starting capture or rendering the inline preview does not activate the
  app's playback audio session.
- Opening PiP, or enabling automatic PiP, activates `.playback` with
  `.mixWithOthers`. The app plays no audio and does not duck other apps.
- Closing PiP, disabling automatic PiP while no window is open, failing to
  open PiP, or stopping the session releases the owned audio session with
  `.notifyOthersOnDeactivation`.
- Audio interruptions are logged; the app does not repeatedly reactivate over
  another media app.
- Screen audio capture is disabled unless the player turns on **Include
  sound** for a recording saved to Photos, and then only for that session:
  the stream captures the device's sound, excluding this app's own, and adds
  an audio output for the recording alone. The picker hides microphone
  controls and the stream registers no microphone output. The bug-report
  movie is always video-only. Whether capturing sound changes how other apps'
  audio behaves is untested; compare a session with it on and off.

Mixing addresses audio-session ownership. It cannot override a media app's
protected-playback restrictions during screen capture. Disabling the debug
movie does not stop screen capture, which recognition still needs.

### Current field result

The user reports that Apple Music becomes silent at capture startup with
Island-only selected. On pressing Play, Music appears to keep playing but
remains inaudible; Ingress sound effects remain audible. Treat this as selective
silence, not a confirmed paused player or a global output failure. Deferring
PiP audio activation was not a sufficient fix. DRM or capture-related suppression
is a hypothesis, not an established diagnosis.

The next build configures mixing before the picker and logs category, mixing,
other-audio playback and PiP ownership before and after `startCapture`. These
flags do not identify a track, DRM status or the capture service's own
audio-session policy. No device result has confirmed this additional change.

The next comparison is the same track and output route with DynamicGlyph
stopped and the system's built-in Screen Recording running. Reproduction there
would show that our PiP code is not required for the symptom. If only
DynamicGlyph reproduces it, investigate the ScreenCaptureKit path and collect
the new audio-state logs rather than declaring an unavoidable DRM restriction.

## Phone checks

### Preview and tab switching

Home, Statistics and Settings offer previews of one shared display layer.
Only the selected tab may attach or size it, and only after its host has a
window and nonempty bounds. Inactive tabs can remain mounted by SwiftUI, so
window attachment alone does not identify the selected tab.

With capture running, visit Home → Statistics → Settings → Home several times.
The selected tab's preview should display the sequence or waiting state rather
than a black rectangle. On Home, tap **Show floating window** while the preview
is visible. Test leaving the app from each tab as well. Repeat after changing
the canvas size and after stopping and restarting capture.

A manual start has a three-second deadline covering both readiness and the
wait for AVKit's start callback. A failed or unacknowledged start must show a
retry message and restore **Show floating window**. Cancellation or an old
deadline must not cancel a newer request.

With session logging enabled, `events.log` records readiness, layer attachment,
bounds, enqueued frames, renderer failures, pool exhaustion and capture
protection when readiness changes, Show is tapped or startup times out. Check
the preview on the phone itself: capture protection can make a recording black
without establishing that the live preview is black.

The simulator tests cover host ownership, hidden-tab layout, tab-switch update
ordering, startup deadlines and nonblack initial frame generation. Actual PiP
opening and automatic background transitions still require these phone checks.

### Audio and placement

1. Play an Apple Music track. Turn **Floating window** off and **Dynamic Island**
   on, leave debug recording off, and start capture. Check whether Music continues or shows
   an error. Save the exact error if present.
2. Enable PiP and leave its window closed and automatic opening off. Music
   should behave as in step 1; there should be no `mixing audio session active`
   event yet.
3. Open PiP. Check music playback and inspect `events.log` for the activation
   and interruption events. Close PiP and confirm `audio session released`.
   Repeat with a locally owned, unprotected audio file to distinguish a
   general interruption from content-specific behavior.
4. Exercise manual open/close, automatic opening, rapid cancellation, and
   stopping capture. No cancelled or previous-session window should reopen.
5. In Ingress, pinch PiP to its smallest size and move it to each corner.
   Record the reported `Window` size and the `render size ..., source=...`
   event. Verify slot indicators, the array, Done and Back separately. A thin
   picture inside a tall black window does not pass the size check.
6. If all corners obstruct necessary controls, use Island-only mode and check
   capture continuity through a whole hack. Do not mark PiP placement solved.

These are device acceptance checks. An iPhone build cannot verify actual
system-window geometry or Apple Music playback.

References: [PiP gestures](https://support.apple.com/en-ie/guide/iphone/iphcc3587b5d/ios),
[mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers),
[screen-recording restrictions](https://support.apple.com/en-jo/102653).
