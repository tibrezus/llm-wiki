import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(__file__)
SCRIPT = os.path.join(HERE, "..", "scripts", "validate-page-size.py")


def run(wiki_dir, *args, config=None):
    cmd = [sys.executable, SCRIPT, wiki_dir]
    if config:
        cmd.append(config)
    cmd += list(args)
    return subprocess.run(cmd, capture_output=True, text=True)


def make_page(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(f"line {i}" for i in range(lines)) + "\n")


class TestPageSize(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.wiki = os.path.join(self.tmp, "wiki")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_under_limit_ok(self):
        make_page(os.path.join(self.wiki, "entities", "a.md"), 10)
        r = run(self.wiki, "--limit", "400")
        self.assertEqual(r.returncode, 0)
        self.assertIn("OK", r.stdout)

    def test_over_limit_warns_non_strict(self):
        make_page(os.path.join(self.wiki, "entities", "big.md"), 5)
        r = run(self.wiki, "--limit", "3")
        self.assertEqual(r.returncode, 0)  # warning mode -> green
        self.assertIn("big.md", r.stdout)
        self.assertTrue("shrink" in r.stdout or "split" in r.stdout)

    def test_over_limit_fails_strict(self):
        make_page(os.path.join(self.wiki, "entities", "big.md"), 5)
        r = run(self.wiki, "--limit", "3", "--strict")
        self.assertEqual(r.returncode, 1)
        self.assertIn("::error", r.stdout)

    def test_config_driven_limit(self):
        make_page(os.path.join(self.wiki, "entities", "x.md"), 12)
        cfg = os.path.join(self.tmp, "wiki.config.yml")
        with open(cfg, "w") as f:
            f.write("project: {name: x, title: x, description: x}\npages:\n  size_limit: 5\n")
        r = run(self.wiki, cfg)
        self.assertEqual(r.returncode, 0)
        self.assertIn("5-line limit", r.stdout)
        self.assertIn("x.md", r.stdout)

    def test_config_strict(self):
        make_page(os.path.join(self.wiki, "entities", "x.md"), 12)
        cfg = os.path.join(self.tmp, "wiki.config.yml")
        with open(cfg, "w") as f:
            f.write("pages:\n  size_limit: 5\n  size_strict: true\n")
        r = run(self.wiki, cfg)
        self.assertEqual(r.returncode, 1)

    def test_missing_wiki_dir(self):
        r = run(os.path.join(self.tmp, "nope"))
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
