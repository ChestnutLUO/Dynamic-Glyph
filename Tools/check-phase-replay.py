#!/usr/bin/env python3
"""Replay a recording through the live display pipeline and check the result.

Unlike check-recording.py, nothing here is annotated into the pipeline: the
phase comes from header text recognition and the slot boundaries come from the
indicator strip, both read from pixels. The expected sequence is the manual
annotation of what the screen showed, and it is only ever compared against.

Requires ffmpeg and the release glyph-replay executable.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/GlyphRecognition"
FIXTURES = PACKAGE / "Tests/GlyphRecognitionTests/Fixtures"
# Read by eye from the recording; see Tools/RecordingResults/2026-09-17/README.md.
EXPECTED = ["see", "truth", "see", "future", "begin"]
EXPECTED_SLOTS = 5


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--start", type=float, default=20.0)
    parser.add_argument("--duration", type=float, default=10.0)
    parser.add_argument("--rate", type=int, default=20)
    parser.add_argument("--size", default="603:1311")
    parser.add_argument("--expect", default=",".join(EXPECTED))
    parser.add_argument("--expect-slots", type=int, default=EXPECTED_SLOTS)
    parser.add_argument("--replay", type=Path, default=PACKAGE / ".build/release/glyph-replay")
    args = parser.parse_args()
    if not args.replay.is_file():
        parser.error("Build first: swift build --package-path Packages/GlyphRecognition "
                     "--build-system native -c release --product glyph-replay")

    with tempfile.TemporaryDirectory(prefix="dynamicglyph-phase-") as temporary:
        frames = Path(temporary)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-ss", str(args.start), "-i", str(args.video), "-t", str(args.duration),
            "-vf", f"fps={args.rate},scale={args.size}", str(frames / "frame-%04d.png")
        ], check=True)
        files = sorted(frames.glob("frame-*.png"))
        if not files:
            raise RuntimeError("ffmpeg produced no frames")
        process = subprocess.run([
            str(args.replay.resolve()),
            "--glyphs", str(FIXTURES / "glyph_line.csv"),
            "--sequences", str(FIXTURES / "glyph.csv"),
            "--interval", str(1.0 / args.rate),
            "--expect", args.expect,
            "--expect-slots", str(args.expect_slots),
            "--quiet", *map(str, files)
        ], text=True, capture_output=True)

    report = json.loads(process.stdout)
    report["source"] = args.video.name
    report["sampleRate"] = args.rate
    report["startSeconds"] = args.start
    report["durationSeconds"] = args.duration
    print(json.dumps(report, indent=2, sort_keys=True))
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "phase-replay.json").write_text(json.dumps(report, indent=2, sort_keys=True))
    if report["failures"]:
        for failure in report["failures"]:
            print(f"FAILED: {failure}")
        raise SystemExit(1)
    print(f"OK: {len(files)} frames, sequence {report['confirmedPrefix']}")


if __name__ == "__main__":
    main()
