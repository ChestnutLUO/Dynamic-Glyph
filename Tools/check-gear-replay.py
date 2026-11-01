#!/usr/bin/env python3
"""Compare gear recognition with assertions that never enter the recognizer.

Videos remain private. Original timestamps are retained; decoded JPEG frames
live in a temporary directory and the recognizer loads only one at a time.
An optional time range is for diagnostic crops, not a full lifecycle replay.
"""
import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures"


def compare(groups, expected):
    failures = []
    assertions = expected.get("groups", [])
    if len(groups) != len(assertions):
        failures.append(f"Group count: expected {len(assertions)}, got {len(groups)}")
    for index, (actual, assertion) in enumerate(zip(groups, assertions)):
        for key in ["recognizedQuantity", "unidentifiedQuantity", "bothPanelsRead", "hackID", "association"]:
            if key in assertion and actual.get(key) != assertion[key]:
                failures.append(f"Group {index + 1} {key}: expected {assertion[key]}, got {actual.get(key)}")
        if "startedBetween" in assertion:
            low, high = assertion["startedBetween"]
            if not low <= actual["startedAt"] <= high:
                failures.append(f"Group {index + 1} starts outside its annotated interval")
        if "entries" in assertion:
            # An optional fifth value asserts whether the quantity was red.
            def entries(panels, colour):
                return sorted((panel["stage"], entry.get("item", "?"), entry.get("level", 0), entry["quantity"])
                              + ((entry.get("multiplied"),) if colour else ())
                              for panel in panels for entry in panel["entries"])
            colour = any(len(entry) == 5 for entry in assertion["entries"])
            wanted = sorted(tuple(entry) for entry in assertion["entries"])
            if entries(actual["panels"], colour) != wanted:
                failures.append(f"Group {index + 1} entries differ")
    return failures


def seconds(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError("needs a number of seconds, 0 or more")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("annotation", type=Path)
    parser.add_argument("--replay", type=Path, default=ROOT / "Packages/GlyphRecognition/.build/debug/glyph-replay")
    parser.add_argument("--mode", choices=["live", "exhaustive", "only"], default="live")
    parser.add_argument("--ocr-latency", type=float, default=0.025)
    parser.add_argument("--constrained", action="store_true",
                        help="replay the app's power-constrained path (Low Power Mode or a hot phone with power saving on)")
    parser.add_argument("--title-pass-cost", default="flat", choices=["flat", "perPass", "measured"],
                        help="lane time of a live gear read: flat (--ocr-latency, the default), perPass "
                             "(--ocr-latency x (1 + title passes); row and quantity rereads uncharged) or measured "
                             "(the sum of the read's measured pass times on this machine)")
    sweep = parser.add_mutually_exclusive_group()
    sweep.add_argument("--extra-title-seconds", type=seconds, metavar="X",
                       help="title-pass cost sweep, with --title-pass-cost flat only: each live gear read holds the "
                            "lane --ocr-latency (exactly as flat) plus X seconds for every title pass beyond the "
                            "read's first, i.e. --ocr-latency + X x max(0, title passes - 1); in a constrained read "
                            "that is the title-zone fallback pass. Absent: unchanged")
    sweep.add_argument("--title-seconds", type=seconds, metavar="X",
                       help="conservative variant, with --title-pass-cost flat only: --ocr-latency + X x title "
                            "passes, the first title pass included. Absent: unchanged")
    parser.add_argument("--gear-lane", default="103", choices=["103", "102"],
                        help="gear lane rules: 103 (default: a new panel stops the gear read in flight, its first read "
                             "has no spacing, constrained analysis at 20 Hz while a panel shows) or 102, for comparison")
    parser.add_argument("--cancel-latency", type=seconds, default=0.05, metavar="L",
                        help="with --gear-lane 103: seconds from a new panel to the stopped read freeing the lane "
                             "(default 0.05)")
    parser.add_argument("--start", type=float, default=0)
    parser.add_argument("--end", type=float)
    parser.add_argument("--game-language", default="en", choices=["auto", "en", "zh-Hans", "zh-Hant", "ja", "ko"])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.extra_title_seconds is not None or args.title_seconds is not None) and args.title_pass_cost != "flat":
        parser.error("--extra-title-seconds and --title-seconds need --title-pass-cost flat (the default)")
    expected = json.loads(args.annotation.read_text())
    with tempfile.TemporaryDirectory(prefix="dynamicglyph-gear-") as temporary:
        directory = Path(temporary)
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "frame=best_effort_timestamp_time", "-of", "json", str(args.video)],
                               check=True, text=True, capture_output=True)
        all_times = [float(frame["best_effort_timestamp_time"]) for frame in json.loads(probe.stdout)["frames"]]
        indices = [i for i, time in enumerate(all_times) if time >= args.start and (args.end is None or time < args.end)]
        if not indices:
            raise RuntimeError("No source frames in selected interval")
        times = [all_times[i] for i in indices]
        timestamps = directory / "times.json"
        timestamps.write_text(json.dumps(times))
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(args.video),
                        "-vf", f"select=between(n\\,{indices[0]}\\,{indices[-1]})", "-fps_mode", "passthrough",
                        "-q:v", "2", str(directory / "frame-%06d.jpg")], check=True)
        frames = sorted(directory.glob("frame-*.jpg"))
        if len(frames) != len(times):
            raise RuntimeError("Decoded frame and timestamp counts differ")
        manifest = directory / "frames.json"
        manifest.write_text(json.dumps([str(frame) for frame in frames]))
        process = subprocess.run([str(args.replay.resolve()), "--glyphs", str(FIXTURES / "glyph_line.csv"),
            "--sequences", str(FIXTURES / "glyph.csv"), "--timestamps", str(timestamps),
            "--frames-manifest", str(manifest), "--gear", args.mode, "--results", "live",
            "--ocr-latency", str(args.ocr_latency), "--game-language", args.game_language, "--quiet"]
            + (["--constrained"] if args.constrained else [])
            + ["--title-pass-cost", args.title_pass_cost]
            + ["--gear-lane", args.gear_lane, "--cancel-latency", repr(args.cancel_latency)]
            + (["--extra-title-seconds", repr(args.extra_title_seconds)] if args.extra_title_seconds is not None else [])
            + (["--title-seconds", repr(args.title_seconds)] if args.title_seconds is not None else []),
            text=True, capture_output=True)
        if process.returncode != 0:
            raise RuntimeError(f"Replay failed ({process.returncode}): {process.stderr[-2000:]}")
        report = json.loads(process.stdout)
    groups = report["gearGroups"]
    failures = report.get("failures", []) + compare(groups, expected)
    report["gearAnnotationFailures"] = failures
    report["source"] = args.video.name
    report["diagnosticRange"] = {"start": args.start, "end": args.end}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps({"failures": failures, "groups": groups}, indent=2))
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
