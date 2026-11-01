#!/usr/bin/env python3
"""Replay a correct-drawing recording; fail on any false 'differs' verdict.

Default annotation: IMG_2003.MP4, shield/mind/clear_all/chaos/xm.
Requires ffmpeg, local reference tables, and the release glyph-replay binary.
Annotations are assertions, never input to the validator.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/GlyphRecognition"
FIXTURES = PACKAGE / "Tests/GlyphRecognitionTests/Fixtures"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expect", default="shield,mind,clear_all,chaos,xm")
    parser.add_argument("--replay", type=Path, default=PACKAGE / ".build/release/glyph-replay")
    args = parser.parse_args()
    if not args.replay.is_file():
        parser.error("Build glyph-replay in release configuration first")
    with tempfile.TemporaryDirectory(prefix="dynamicglyph-input-") as temporary:
        frames = Path(temporary)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(args.video),
            "-vf", "fps=20,scale=562:-1", str(frames / "frame-%05d.png")
        ], check=True)
        files = sorted(frames.glob("frame-*.png"))
        if not files:
            raise RuntimeError("ffmpeg produced no frames")
        replay = subprocess.run([
            str(args.replay.resolve()), "--glyphs", str(FIXTURES / "glyph_line.csv"),
            "--sequences", str(FIXTURES / "glyph.csv"), "--interval", "0.05",
            "--expect", args.expect, "--expect-slots", str(len(args.expect.split(","))),
            "--expect-correct-input", "--quiet", *map(str, files)
        ], capture_output=True, text=True)
    if not replay.stdout.strip():
        raise RuntimeError(replay.stderr or "replay produced no report")
    report = json.loads(replay.stdout)
    report.update(source=args.video.name, sampleRate=20, width=562)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    for result in report["inputChecks"]:
        print(f"Slot {result['slotIndex'] + 1} ({result['expectedGlyph']}): "
              f"{result['verdict']}" + (f" ({result['reason']})" if result['reason'] else ""))
    print(json.dumps(report["inputSummary"], sort_keys=True))
    for failure in report["failures"]:
        print(f"FAILED: {failure}")
    raise SystemExit(replay.returncode or (1 if report["failures"] else 0))


if __name__ == "__main__":
    main()
