#!/usr/bin/env python3
"""Replay original video frames/timestamps and compare conclusion annotations.

The annotation is an assertion file only: nothing from it enters recognition.
Private movies stay local; output contains machine readings and comparisons.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("annotation", type=Path)
    parser.add_argument("--replay", type=Path, default=ROOT / "Packages/GlyphRecognition/.build/debug/glyph-replay")
    parser.add_argument("--mode", choices=["live", "exhaustive"], default="live")
    parser.add_argument("--ocr-latency", type=float, default=0.025)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    expected = json.loads(args.annotation.read_text())
    with tempfile.TemporaryDirectory(prefix="dynamicglyph-result-") as temporary:
        directory = Path(temporary)
        probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                "frame=best_effort_timestamp_time", "-of", "json", str(args.video)],
                               check=True, text=True, capture_output=True)
        times = [float(frame["best_effort_timestamp_time"]) for frame in json.loads(probe.stdout)["frames"]]
        timestamps = directory / "times.json"
        timestamps.write_text(json.dumps(times))
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(args.video),
                        "-fps_mode", "passthrough", str(directory / "frame-%05d.png")], check=True)
        frames = sorted(directory.glob("frame-*.png"))
        if len(frames) != len(times):
            raise RuntimeError("Decoded frame and timestamp counts differ")
        process = subprocess.run([str(args.replay.resolve()), "--glyphs", str(FIXTURES / "glyph_line.csv"),
            "--sequences", str(FIXTURES / "glyph.csv"), "--timestamps", str(timestamps),
            "--results", args.mode, "--ocr-latency", str(args.ocr_latency), "--quiet", *map(str, frames)],
            text=True, capture_output=True)
    if not process.stdout.strip():
        raise RuntimeError(f"Replay returned {process.returncode}: {process.stderr}")
    report = json.loads(process.stdout)
    failures = list(report["failures"])
    summaries = report["results"]
    if len(summaries) != 1:
        failures.append(f"Expected one hack, got {len(summaries)}")
    else:
        result = summaries[0]
        for key in ["glyphs", "finalHackingBonus", "finalSpeedBonus", "outcomes"]:
            if result.get(key) != expected[key]:
                failures.append(f"{key}: expected {expected[key]}, got {result.get(key)}")
        actual = [entry["attemptID"] for entry in result["comparisons"]]
        if actual != expected["finalValidatorAttempts"]:
            failures.append(f"Final attempt links: {actual}")
        disagreements = [entry for entry in result["comparisons"] if entry["status"] == "disagreement"]
        if disagreements:
            failures.append(f"Validator disagreements: {disagreements}")
        report["resultCoverage"] = {
            "unknownOutcomes": result["outcomes"].count("unknown"),
            "unknownAssociations": sum(entry["status"] == "unknownAssociation" for entry in result["comparisons"]),
            "validatorCoverageGaps": sum(entry["status"] == "coverageGap" for entry in result["comparisons"]),
            "disagreements": len(disagreements),
        }
    report["annotationFailures"] = failures
    report["source"] = args.video.name
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps({"failures": failures, "results": summaries, "coverage": report.get("resultCoverage")}, indent=2))
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
