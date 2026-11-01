"""Exercise maintenance scripts only in disposable repositories; no network.

Run from any directory: python3 scripts/tests/test_repository_scripts.py
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path('Packages/GlyphRecognition/Tests/GlyphRecognitionTests/Fixtures')
TABLES = [FIXTURES / 'glyph_line.csv', FIXTURES / 'glyph.csv']


class RepositoryScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dg-script-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM='1', LC_ALL='C', TMPDIR=str(self.root))
        self.run_command('git', 'init', '--quiet')
        self.git('config', 'user.name', 'Repository Script Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        (self.repo / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts' / 'fetch-reference-data.sh', self.repo / 'scripts' / 'fetch-reference-data.sh')

    def run_command(self, *args, check=True):
        result = subprocess.run(args, cwd=self.repo, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if check and result.returncode:
            self.fail(f'{args} exited {result.returncode}:\n{result.stdout}')
        return result

    def git(self, *args):
        return self.run_command('git', *args).stdout.strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    def mock_fetch(self, source):
        # A fake git supplies bytes from disk. The actual downloader must still
        # select its pinned revision and validate the raw file hashes itself.
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        fake = bin_dir / 'git'
        fake.write_text('''#!/bin/sh
set -eu
if [ "$1" = init ]; then mkdir -p "$3"; exit 0; fi
case "$3" in
fetch)
    test "$7" = 109f6c32d24c9f219e946a1423642390db6ce86b
    cp "$MOCK_SOURCE"/* "$2/"
    ;;
checkout) ;;
rev-parse) echo 109f6c32d24c9f219e946a1423642390db6ce86b ;;
*) exit 2 ;;
esac
''')
        fake.chmod(0o755)
        self.env['PATH'] = str(bin_dir) + os.pathsep + self.env['PATH']
        self.env['MOCK_SOURCE'] = str(source)

    def fetch(self):
        return subprocess.run(['sh', 'scripts/fetch-reference-data.sh'], input='y\n',
                              cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_bad_download_keeps_both_local_tables(self):
        source = self.root / 'download'
        source.mkdir()
        # First file is valid when the optional reference input is available;
        # second is corrupt. Neither installed table may be replaced.
        first = ROOT / TABLES[0]
        (source / 'glyph_line.csv').write_bytes(first.read_bytes() if first.exists() else b'invalid first file')
        (source / 'glyph.csv').write_bytes(b'corrupt download')
        for path in TABLES:
            self.write(path, b'keep my existing input')
        self.mock_fetch(source)
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAILED', result.stdout)
        for path in TABLES:
            self.assertEqual((self.repo / path).read_bytes(), b'keep my existing input')

    def test_pinned_download_installs_exact_bytes(self):
        if not all((ROOT / path).exists() for path in TABLES):
            self.skipTest('Optional reference tables are absent')
        source = self.root / 'download'
        source.mkdir()
        for path in TABLES:
            shutil.copy2(ROOT / path, source / path.name)
            self.write(path, b'old local input')
        self.mock_fetch(source)
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stdout)
        for path in TABLES:
            self.assertEqual((self.repo / path).read_bytes(), (ROOT / path).read_bytes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
