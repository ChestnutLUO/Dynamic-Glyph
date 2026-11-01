#!/usr/bin/env python3
"""Replay the manually inspected 2026-09-17 hack; no automatic phase inference.

Requires ffmpeg and the release glyph-recognize executable. Expected labels and
edges are geometric annotations of the visible presentation, not predictions
from the sequence table. Times are on a 20 Hz sample grid (not exact game events).
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Packages/GlyphRecognition"
FIXTURES = PACKAGE / "Tests/GlyphRecognitionTests/Fixtures"
SLOTS = [
    (25450, 25700, "see", ["0-3"], 25500),
    (25800, 26100, "truth", ["3-5", "3-6", "4-5", "4-7", "5-6", "5-7"], 25900),
    (26200, 26500, "see", ["0-3"], 26300),
    (26600, 26850, "future", ["2-4", "4-7", "7-9"], 26700),
    (26950, 27250, "begin", ["0-6", "6-a", "7-a"], 27100),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--save-fixtures", action="store_true")
    parser.add_argument("--recognizer", type=Path, default=PACKAGE / ".build/release/glyph-recognize")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.recognizer.is_file():
        parser.error("Build first: cd Packages/GlyphRecognition && swift build --build-system native -c release --product glyph-recognize")

    with tempfile.TemporaryDirectory(prefix="dynamicglyph-replay-") as temporary:
        frames = Path(temporary)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", "20", "-i", str(args.video),
            "-t", "10", "-vf", "fps=20,scale=603:1311", str(frames / "frame-%04d.png")
        ], check=True)
        files = sorted(frames.glob("frame-*.png"))
        if len(files) != 200:
            raise RuntimeError(f"Expected 200 samples from 20-30 seconds, got {len(files)}")
        calibration = frames / "frame-0104.png"  # sample grid 25.150 s, empty array
        process = subprocess.run([
            str(args.recognizer.resolve()), "--glyphs", str(FIXTURES / "glyph_line.csv"),
            "--calibration", str(calibration), *map(str, files)
        ], check=True, text=True, capture_output=True)
        records = [json.loads(line) for line in process.stdout.splitlines()]
        if len(records) != 200:
            raise RuntimeError(f"Expected 200 analysis records, got {len(records)}")
        failures, labeled, blanks = [], 0, 0
        for index, record in enumerate(records):
            time = 20000 + index * 50
            record["sampleTimeMilliseconds"] = time
            record["file"] = Path(record["file"]).name
            slot = next((slot for slot in SLOTS if slot[0] <= time < slot[1]), None)
            if slot:
                labeled += 1
                exact = [candidate["glyph"] for candidate in record["candidates"] if candidate["edgeDistance"] == 0]
                if record["state"] != "uniqueVisibleShape" or exact != [slot[2]] or sorted(record["edges"]) != sorted(slot[3]):
                    failures.append({"time": time, "expected": slot[2], "actual": record})
            elif 25300 <= time < 27300:
                blanks += 1
                if record["state"] != "noStroke" or record["candidates"]:
                    failures.append({"time": time, "expected": "noStroke", "actual": record})

        with args.video.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        summary = {
            "source": args.video.name, "sha256": digest,
            "sampleRate": 20, "sampleIntervalSeconds": [20, 30], "analysisSize": [603, 1311],
            "calibrationSampleMilliseconds": 25150, "totalSamples": len(records),
            "labeledPresentationSamples": labeled, "blankPresentationSamples": blanks,
            "manuallyAnnotatedSequence": [slot[2] for slot in SLOTS],
            "slots": [{"startMilliseconds": a, "endMillisecondsExclusive": b, "glyph": name,
                       "edges": edges, "representativeMilliseconds": representative}
                      for a, b, name, edges, representative in SLOTS],
            "failures": failures,
            "limits": "One recording; manual phase/slot annotations; 20 Hz sampling; not an end-to-end live test."
        }
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        (args.output / "frames.jsonl").write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records))
        if args.save_fixtures:
            target = FIXTURES / "Assets" / "Screenshots" / "Recording"
            target.mkdir(parents=True, exist_ok=True)
            times = [25150, 23600, 28550] + [slot[4] for slot in SLOTS]
            for time in times:
                number = (time - 20000) // 50 + 1
                shutil.copyfile(frames / f"frame-{number:04d}.png", target / f"sample-{time}.png")

        # Contact sheets preserve independent visual evidence for every sample
        # in the annotated presentation interval, including blank gaps.
        for first, name in [(107, "presentation-25300-26250.jpg"), (127, "presentation-26300-27250.jpg")]:
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", "20",
                "-start_number", str(first), "-i", str(frames / "frame-%04d.png"),
                "-vf", "scale=240:-1,tile=5x4", "-frames:v", "1", str(args.output / name)
            ], check=True)
        print(json.dumps(summary, indent=2))
        if failures:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
