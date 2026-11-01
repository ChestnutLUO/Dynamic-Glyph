#!/usr/bin/env python3
"""Compare command acknowledgements from a private movie with sanitized annotations.

Annotations are assertions only. Original timestamps, not frame numbers, drive
recognition. A 20-Hz movie cannot establish coverage of the 60-Hz capture path.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video', type=Path)
    parser.add_argument('annotation', type=Path)
    parser.add_argument('--replay', type=Path, default=ROOT / 'Packages/GlyphRecognition/.build/release/glyph-replay')
    parser.add_argument('--mode', choices=['live', 'exhaustive'], default='live')
    parser.add_argument('--ocr-latency', type=float, default=0.025)
    parser.add_argument('--game-language', default='en', choices=['auto', 'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko'])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    expected = json.loads(args.annotation.read_text())
    with tempfile.TemporaryDirectory(prefix='dynamicglyph-command-replay-') as tmp:
        directory = Path(tmp)
        probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                'frame=best_effort_timestamp_time', '-of', 'json', str(args.video)],
                               check=True, capture_output=True, text=True)
        times = [float(f['best_effort_timestamp_time']) for f in json.loads(probe.stdout)['frames']]
        timestamps = directory / 'times.json'
        timestamps.write_text(json.dumps(times))
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(args.video), '-fps_mode', 'passthrough',
                        '-threads', '1', str(directory / 'frame-%05d.png')], check=True)
        frames = sorted(directory.glob('frame-*.png'))
        if len(frames) != len(times):
            raise RuntimeError('Frame count and timestamp count differ')
        manifest = directory / 'frames.json'
        manifest.write_text(json.dumps([str(p) for p in frames]))
        result = subprocess.run([str(args.replay.resolve()), '--glyphs', str(FIXTURES / 'glyph_line.csv'),
                                 '--sequences', str(FIXTURES / 'glyph.csv'), '--timestamps', str(timestamps),
                                 '--frames-manifest', str(manifest), '--commands', args.mode,
                                 '--results', 'live', '--gear', 'live', '--ocr-latency', str(args.ocr_latency),
                                 '--game-language', args.game_language,
                                 '--quiet'], capture_output=True, text=True)
    if not result.stdout.strip():
        raise RuntimeError(result.stderr)
    report = json.loads(result.stdout)
    failures = list(report['failures'])
    actual = report['results']
    if len(actual) != len(expected['hacks']):
        failures.append(f"Hack count: expected {len(expected['hacks'])}, got {len(actual)}")
    for wanted, result in zip(expected['hacks'], actual):
        commands = result.get('commands') or {}
        for field in ['presentation', 'gear']:
            value = commands.get(field, {})
            observed = value.get('lastObserved') if value.get('status') == 'confirmed' else value.get('status')
            if observed != wanted[field]:
                failures.append(f"Hack {wanted['hackID']} {field}: expected {wanted[field]}, got {observed}")
        if 'mode' in wanted and commands.get('mode') != wanted['mode']:
            failures.append(f"Hack {wanted['hackID']} mode: {commands.get('mode')}")
    report['annotationFailures'] = failures
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(json.dumps({'failures': failures, 'commands': [r.get('commands') for r in actual]}, indent=2))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
