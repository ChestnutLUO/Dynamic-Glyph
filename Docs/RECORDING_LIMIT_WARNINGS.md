# Recording limit warnings

Each Photos recording and bug-report recording gets one warning, whichever
threshold is observed first:

- File size reaches 90% of its cap (1 GiB for Photos, 300 MiB for bug reports;
  the existing interface labels these as 1 GB and 300 MB).
- One minute remains before its duration cap (30 minutes or 10 minutes).

The warning uses the recorder's existing one-second status reports. File-size
checks use the actual file size, not a bitrate estimate. Duration checks use
both elapsed monotonic time and source coverage, matching the recorder's two
duration limits. A static screen therefore still approaches the wall-time
limit. A recording with no written frames does not warn. If a status update
has already reached a cap, it does not send a misleading advance warning.

Enabling either recording option requests local-notification permission.
Denial does not prevent recording. The warning also appears on Home and in
the corresponding Settings section. Settings explains how to allow
notifications if permission was denied. Permission is checked again at delivery,
without prompting during gameplay. Alerts follow the user's iOS notification
and Focus settings; they are not critical or time-sensitive notifications.

Stopping, finalizing, a failed capture start, or replacing a recording clears
its warning and removes its pending/delivered notification. Unique recording
IDs prevent late progress or asynchronous notification work from leaking into
a later recording. A late notification-center completion is removed again.
The automatic caps and Glyph recognition behavior are unchanged.

## Verification

Simulator tests cover both size and time thresholds, one warning per recording,
empty/finished recordings, finalization waiting on a blocked encoder, denied
permission, concurrent recording types, replacements, late progress, stopping
during authorization or notification submission, and delivery failures.

On a phone, enable a recording and allow notifications. Leave Dynamic Glyph
for Ingress. Check a bug-report warning around nine minutes or a Photos warning
around 29 minutes, unless the size warning arrives first. Confirm the banner
identifies the correct recording and recognition continues. Repeat with
permission denied to check the in-app warning, and stop after a warning to
confirm it disappears from Notification Center. Size-limit testing needs a
recording that reaches 90% of its byte cap before the time warning.
