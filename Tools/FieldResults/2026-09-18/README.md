# First live recognition field report

Source: `spikeB-2026-09-18T14-11-47Z` at the repository root. Raw inputs are
unchanged. [summary.json](summary.json) records source hashes and statistics.

## Result

Recognition ran on the phone while Ingress was visible. The log contains
**749 samples over 41.074 seconds**, at 603 × 1311, with no recorded conversion
or recognition errors. Calibration first succeeds at sample 381 / 21.129 s,
on the empty array in the command channel. Not finding an array before that
is not a measured recognition failure; those frames were not saved.

The four presentation runs in the log are:

| Logged Glyph | Samples | Elapsed seconds | Clean matching samples | Saved presentation screenshot |
| --- | --- | --- | --- | --- |
| change | 443–448 | 24.229–24.479 | 6 | Yes |
| perspective | 451–455 | 24.629–24.829 | 5 | No |
| begin | 458–463 | 24.979–25.229 | 6 | No |
| new | 466–471 | 25.379–25.629 | 6 | No |

All **23** samples have `uniqueVisibleShape`. Samples across this presentation,
including intervening blanks, are about 50.008 ms apart, with no sampling gap
over 51 ms. Unexplained ink stays between about 9.8% and 15.5% for these shapes.
The first saved player-input screenshot is at 26.680 s, after all four runs.

The [change screenshot](../../../spikeB-2026-09-18T14-11-47Z/glyph-00443.png)
visibly agrees with edges `5-6, 5-a, 7-a`. It shows "Incoming glyph sequence"
and four slot indicators. Later blank screenshots show indicators two,
three and four. The last three presented shapes have **no saved pixels**, so
their correctness cannot be independently established from this report.
Do not call this a four-of-four visual accuracy test.

`change,perspective,begin,new` exists in the reference sequence table, but that
is a consistency check, not independent truth. The table also contains
`change,perspective` and `change,perspective,begin,new,resistance`; the expected
four-slot count is useful additional evidence the current predictor does not
consume. No live sequence prediction or phase classification was performed.

## Other phases

The saved images show command entry, presentation, player input, a completion
screen, and the map. All 23 clean shape matches occur in the four presentation
runs. Another **118** samples have geometrically exact edges but are downgraded
to `unexplainedInk`. They include command/player trails and a false `link`
edge on the completion dialog. These must not be counted as accepted Glyphs.
This run provides useful negative examples but does not prove phase detection.

State totals: 439 waiting for calibration, 53 no stroke, 116 unrecognized
stroke, 118 unexplained ink, 23 unique visible shape.

## Timing and evidence bugs

- Median processing: **15.74 ms**; p95: **32.57 ms**; maximum: **199.30 ms**.
  These measurements exclude callback queue delay, JSON writes and disk sync.
- The 29 PNG-saving samples have median **62.93 ms**. 24 exceed the 50 ms
  sampling interval. The other 720 samples have median **15.58 ms**; four
  exceed 50 ms. Saving PNGs synchronously is a real source of stalls.
- `frames.csv` contains only its header, and the stop event says zero frames,
  despite 749 recognition samples and 29 PNGs. The old telemetry path did
  not record frames. This also means CPU, thermal, memory and background-state
  measurements are unavailable. The report cannot distinguish whether the
  second output registration or the stream-identity guard caused the loss.
- The screenshot limiter consumed observation changes even when it skipped
  the actual write. A saved blank just before a shape prevented saving that
  whole held shape. This explains the three missing presentation screenshots.

## Changes made after reviewing this run

1. Use one screen-output receiver and explicitly forward every valid screen
   callback to telemetry, keyed by capture session rather than stream-object
   identity. Recognition remains throttled independently.
2. Base snapshot eligibility on the last image actually queued. A throttled
   transition remains eligible on later frames of the same held shape.
3. Encode PNGs on a separate serial queue with at most two outstanding images.
   `snapshots.jsonl` records save success/failure and encoding time; recognition
   schema version 2 marks snapshot filenames as queued. Stop waits for pending
   writes before reporting completion.

The regression harness uses the actual Swift scheduler and replays this log.
It now selects presentation samples **443, 453, 461, 469**, covering each of
the four logged shapes. It also checks retry/cap behavior and the asynchronous
PNG writer. This cannot recover missing screenshots from the original run.

An iPhone SDK build and the snapshot regression harness validate these code
changes. **A fresh phone run is still required** to confirm nonempty capture
telemetry, retained screenshots for all slots, and improved device timing.
