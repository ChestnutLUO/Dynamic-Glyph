#!/usr/bin/env python3
"""Ablation study: replay every annotated recording with one pipeline
component switched off at a time and score each run against the manual
annotation.

Each variant is the live pipeline (glyph-replay) less the components it names,
or the unchanged pipeline fed a thinner frame stream. The annotation is only
ever compared against; it never enters a run. Requires Python 3.11+, ffmpeg,
the release glyph-replay executable and both reference tables.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/GlyphRecognition"
FIXTURES = PACKAGE / "Tests/GlyphRecognitionTests/Fixtures"

# (name, ablations passed to glyph-replay, keep every n-th frame)
VARIANTS = [
    ("baseline", [], 1),
    ("-header", ["header"], 1),
    ("-strip", ["strip"], 1),
    ("-timer", ["timer"], 1),
    ("-header -timer", ["header", "timer"], 1),
    ("-layout-check", ["layout-check"], 1),
    ("-calibration-cache", ["calibration-cache"], 1),
    ("-ink-check", ["ink-check"], 1),
    ("-stability", ["stability"], 1),
    ("-slot-votes", ["slot-votes"], 1),
    ("-indicator-phase", ["indicator-phase"], 1),
    ("-last-slot-release", ["last-slot-release"], 1),
    ("-timer -last-slot-release", ["timer", "last-slot-release"], 1),
    ("10 Hz", [], 2),
    ("10 Hz -strip", ["strip"], 2),
    ("5 Hz", [], 4),
    ("5 Hz -stability", ["stability"], 4),
]
SLOT_EVENTS = {"slotCommitted", "slotInferred"}
# Commits are expected from a little before the first Glyph appears (the
# indicator moves first) until the probe.
WINDOW_LEAD = 0.3


def extract(recording, spec, directory):
    source = ROOT / spec["source"]
    if not source.is_file():
        raise SystemExit(f"missing recording for {recording}: {source}")
    directory.mkdir(parents=True)
    if recording == "s0917":
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(source),
                        "-vf", "fps=20,scale=603:1311", str(directory / "f-%06d.png")], check=True)
        files = sorted(directory.glob("f-*.png"))
        return files, [index * 0.05 for index in range(len(files))]
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(source),
                    "-fps_mode", "passthrough", str(directory / "f-%06d.png")], check=True)
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                            "-show_entries", "frame=pts_time", "-of", "csv=p=0", str(source)],
                           check=True, capture_output=True, text=True)
    times = [float(line.strip().strip(",")) for line in probe.stdout.splitlines() if line.strip().strip(",")]
    files = sorted(directory.glob("f-*.png"))
    if len(files) != len(times) or any(a >= b for a, b in zip(times, times[1:])):
        raise SystemExit(f"{recording}: {len(files)} frames but {len(times)} usable timestamps")
    return files, times


def replay(executable, files, times, ablations, step, probes, workdir, label):
    files, times = files[::step], times[::step]
    stem = workdir / label.replace(" ", "_")
    (stem.with_suffix(".times.json")).write_text(json.dumps(times))
    (stem.with_suffix(".probes.json")).write_text(json.dumps(probes))
    command = [str(executable), "--glyphs", str(FIXTURES / "glyph_line.csv"),
               "--sequences", str(FIXTURES / "glyph.csv"), "--quiet",
               "--timestamps", str(stem.with_suffix(".times.json")),
               "--probes", str(stem.with_suffix(".probes.json"))]
    if ablations:
        command += ["--ablate", ",".join(ablations)]
    process = subprocess.run(command + [str(f) for f in files], capture_output=True, text=True)
    if process.returncode not in (0, 1) or not process.stdout.strip():
        raise RuntimeError(f"{label}: glyph-replay failed: {process.stderr.strip()}")
    return json.loads(process.stdout)


def score_hack(hack, snapshot, events):
    """What the display held at the probe, slot by slot, against the annotation."""
    held = {slot["index"]: slot for slot in snapshot["slots"]}
    tally = {"correct": 0, "inferredCorrect": 0, "wrongConfirmed": 0, "wrongInferred": 0,
             "notRecovered": 0, "visible": 0}
    for index, truth in enumerate(hack["slots"]):
        if truth is None:
            continue
        tally["visible"] += 1
        slot = held.get(index, {})
        status, glyph = slot.get("status"), slot.get("glyph")
        if status == "confirmed":
            tally["correct" if glyph == truth else "wrongConfirmed"] += 1
        elif status == "inferred":
            tally["inferredCorrect" if glyph == truth else "wrongInferred"] += 1
        else:
            tally["notRecovered"] += 1
    prefix = snapshot["confirmedPrefix"]
    truth = hack["slots"]
    exact = (hack["complete"] and prefix == truth
             and snapshot["expectedSlotCount"] == hack["slotCount"])

    def resolved_at(key):
        """Fewest confirmed Glyphs after which the table named the whole
        sequence correctly, when the prefix itself is correct."""
        for outlook in snapshot["prefixOutlooks"]:
            observed = outlook["observed"]
            result = outlook[key]
            if prefix[:observed] != truth[:observed]:
                return None
            if result["state"] == "resolved" and prefix[:observed] + result["predictedSuffix"] == truth:
                return observed
        return None

    def misresolved(key):
        """Prefixes after which the table named one sequence, and the wrong one."""
        return sum(1 for outlook in snapshot["prefixOutlooks"]
                   if outlook[key]["state"] == "resolved"
                   and prefix[:outlook["observed"]] + outlook[key]["predictedSuffix"] != truth)

    last_commit = [e["time"] for e in events
                   if e["kind"] == "slotCommitted" and e["slotIndex"] == hack["slotCount"] - 1
                   and hack["presented"][0] - WINDOW_LEAD <= e["time"] <= hack["probe"]]
    return {
        "id": hack["id"], **tally,
        "slotCountCorrect": snapshot["expectedSlotCount"] == hack["slotCount"],
        "exact": exact,
        "resolvedAfterWithCount": resolved_at("withSlotCount") if hack["complete"] else None,
        "resolvedAfterWithoutCount": resolved_at("withoutSlotCount") if hack["complete"] else None,
        "misresolvedWithCount": misresolved("withSlotCount"),
        "misresolvedWithoutCount": misresolved("withoutSlotCount"),
        "stateAtProbe": snapshot["trackingState"],
        "lastSlotLatency": (last_commit[-1] - hack["presented"][1]) if exact and last_commit else None,
        "held": [(s["status"], s["glyph"]) for s in snapshot["slots"]],
    }


def summarize(name, hacks, reports):
    rows = [row for report in reports.values() for row in report["hacks"]]
    complete = [row for row, hack in zip(rows, hacks) if hack["complete"]]
    visible = sum(r["visible"] for r in rows)
    latencies = [r["lastSlotLatency"] for r in rows if r["lastSlotLatency"] is not None]
    with_count = [r["resolvedAfterWithCount"] for r in complete]
    without_count = [r["resolvedAfterWithoutCount"] for r in complete]
    return {
        "variant": name,
        "visibleSlots": visible,
        "correct": sum(r["correct"] for r in rows),
        "inferredCorrect": sum(r["inferredCorrect"] for r in rows),
        "wrongConfirmed": sum(r["wrongConfirmed"] for r in rows),
        "wrongInferred": sum(r["wrongInferred"] for r in rows),
        "notRecovered": sum(r["notRecovered"] for r in rows),
        "exactHacks": sum(r["exact"] for r in complete),
        "completeHacks": len(complete),
        "slotCountCorrect": sum(r["slotCountCorrect"] for r in rows),
        "hacks": len(rows),
        "spuriousCommits": sum(report["spuriousCommits"] for report in reports.values()),
        "lateCommits": sum(report["lateCommits"] for report in reports.values()),
        "misresolvedWithCount": sum(r["misresolvedWithCount"] for r in rows),
        "misresolvedWithoutCount": sum(r["misresolvedWithoutCount"] for r in rows),
        "medianLastSlotLatency": statistics.median(latencies) if latencies else None,
        "resolvedWithCount": [k for k in with_count if k is not None],
        "resolvedWithoutCount": [k for k in without_count if k is not None],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--annotations", type=Path,
                        default=ROOT / "Tools/AblationResults/2026-09-22/annotations.json")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--replay", type=Path, default=PACKAGE / ".build/release/glyph-replay")
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    args = parser.parse_args()
    if not args.replay.is_file():
        parser.error("Build first: swift build --package-path Packages/GlyphRecognition "
                     "--build-system native -c release --product glyph-replay")
    for table in ("glyph_line.csv", "glyph.csv"):
        if not (FIXTURES / table).is_file():
            parser.error(f"missing {table}; see {FIXTURES / 'PROVENANCE.md'}")
    annotations = json.loads(args.annotations.read_text())
    hacks = annotations["hacks"]
    recordings = annotations["recordings"]

    with tempfile.TemporaryDirectory(prefix="dynamicglyph-ablation-") as temporary:
        workdir = Path(temporary)
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            frames = dict(zip(recordings, pool.map(
                lambda name: extract(name, recordings[name], workdir / name), recordings)))
            jobs = {}
            for name, ablations, step in VARIANTS:
                for recording in recordings:
                    probes = [h["probe"] for h in hacks if h["recording"] == recording]
                    files, times = frames[recording]
                    jobs[(name, recording)] = pool.submit(
                        replay, args.replay, files, times, ablations, step, probes,
                        workdir / recording, f"{name}-{recording}")
            raw = {key: job.result() for key, job in jobs.items()}

    results = []
    for name, ablations, step in VARIANTS:
        reports = {}
        for recording in recordings:
            report = raw[(name, recording)]
            own = [h for h in hacks if h["recording"] == recording]
            snapshots = sorted(report["probes"], key=lambda p: p["probeTime"])
            rows = [score_hack(hack, snapshot, report["events"])
                    for hack, snapshot in zip(sorted(own, key=lambda h: h["probe"]), snapshots)]
            if len(snapshots) != len(own):
                raise RuntimeError(f"{name} {recording}: {len(snapshots)} probes for {len(own)} hacks")
            own.sort(key=lambda h: h["probe"])
            windows = [(h["presented"][0] - WINDOW_LEAD, h["probe"]) for h in own]
            outside = [e for e in report["events"] if e["kind"] in SLOT_EVENTS
                       and not any(a <= e["time"] <= b for a, b in windows)]

            def late(event):
                """The right Glyph for the right slot of the hack just shown,
                only committed after its probe."""
                earlier = [h for h in own if h["probe"] < event["time"]]
                if not earlier:
                    return False
                slots = earlier[-1]["slots"]
                index = event["slotIndex"]
                return index is not None and index < len(slots) and slots[index] == event["glyph"]
            reports[recording] = {"hacks": rows,
                                  "lateCommits": sum(1 for e in outside if late(e)),
                                  "spuriousCommits": sum(1 for e in outside if not late(e)),
                                  "outside": outside, "phaseSources": report["phaseSources"]}
        ordered = [h for recording in recordings for h in sorted(
            (h for h in hacks if h["recording"] == recording), key=lambda h: h["probe"])]
        summary = summarize(name, ordered, reports)
        summary["ablations"] = ablations
        summary["frameStep"] = step
        results.append({"summary": summary, "recordings": reports})

    header = ("| variant | correct | inferred ✓ | wrong | not recovered | exact hacks | slot count "
              "| spurious | late | median last-slot latency |")
    print(header)
    print("|" + "---|" * 10)
    for result in results:
        s = result["summary"]
        latency = "–" if s["medianLastSlotLatency"] is None else f"{s['medianLastSlotLatency']:.2f} s"
        print(f"| {s['variant']} | {s['correct']}/{s['visibleSlots']} | {s['inferredCorrect']} "
              f"| {s['wrongConfirmed'] + s['wrongInferred']} | {s['notRecovered']} "
              f"| {s['exactHacks']}/{s['completeHacks']} | {s['slotCountCorrect']}/{s['hacks']} "
              f"| {s['spuriousCommits']} | {s['lateCommits']} | {latency} |")
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "ablation-results.json").write_text(json.dumps(results, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
