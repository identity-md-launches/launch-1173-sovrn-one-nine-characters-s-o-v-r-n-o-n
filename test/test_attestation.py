"""Offline attestation regression tests; run after or alongside the documented build checks."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("attest", ROOT / "script/attest.py")
attest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(attest)


class AttestationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Real pinned compiler artifacts; only redundant builds in temporary copies are skipped.
        attest.command("forge", "build")

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sovrn-attestation-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for name in ("src", "script", "test"):
            shutil.copytree(ROOT / name, self.root / name,
                            ignore=shutil.ignore_patterns("scratch", "__pycache__"))
        for name in ("README.md", "launch.json", "foundry.toml"):
            shutil.copyfile(ROOT / name, self.root / name)
        for name in ("lib", "out"):
            (self.root / name).symlink_to(ROOT / name, target_is_directory=True)
        # This is the schema-valid manifest reported by the reviewer.
        self.manifest = json.loads((self.root / "launch.json").read_text())
        self.manifest.pop("chainId", None)
        self.write_manifest()
        original_command = attest.command
        self.enterContext(patch.object(attest, "ROOT", self.root))
        self.enterContext(patch.object(attest, "OUTPUT", self.root / "launch-attestation.json"))
        self.enterContext(patch.object(
            attest, "command", side_effect=lambda *args:
            "" if args == ("forge", "build") else original_command(*args)))

    def write_manifest(self):
        (self.root / "launch.json").write_text(json.dumps(self.manifest))

    def run_cli(self, *args):
        with patch.object(sys, "argv", ["attest.py", *args]), contextlib.redirect_stdout(io.StringIO()) as output:
            attest.main()
        return output.getvalue()

    def test_five_key_manifest_generates_and_checks(self):
        self.assertIn("Wrote launch-attestation.json.", self.run_cli())
        self.assertIn("Launch manifest and attestation match the current build.", self.run_cli("--check"))
        record = json.loads(attest.OUTPUT.read_text())
        self.assertEqual(record["chainId"], 4663)
        self.assertEqual(record["deliverySha256"]["launch.json"],
                         hashlib.sha256((self.root / "launch.json").read_bytes()).hexdigest())

    def test_changed_manifest_fails_check_without_rewriting_record(self):
        self.run_cli()
        original = attest.OUTPUT.read_bytes()
        self.manifest["notes"] += " Changed deployment notes."
        self.write_manifest()
        with self.assertRaisesRegex(AssertionError, "launch attestation differs"):
            self.run_cli("--check")
        self.assertEqual(attest.OUTPUT.read_bytes(), original)

    def test_added_or_changed_delivery_file_requires_regeneration(self):
        self.run_cli()
        added = self.root / "test/nested/attestation-probe.md"
        added.parent.mkdir()
        for content in ("New delivered test evidence.\n", "Changed delivered test evidence.\n"):
            added.write_text(content)
            with self.assertRaisesRegex(AssertionError, "launch attestation differs"):
                self.run_cli("--check")
            self.run_cli()
            self.run_cli("--check")
            record = json.loads(attest.OUTPUT.read_text())
            self.assertEqual(record["deliverySha256"]["test/nested/attestation-probe.md"],
                             hashlib.sha256(added.read_bytes()).hexdigest())
        expected = {str(p.relative_to(self.root)) for p in (self.root / "test").rglob("*") if p.is_file()}
        self.assertTrue(expected <= record["deliverySha256"].keys())

    def test_extra_manifest_keys_are_rejected(self):
        self.manifest["chainId"] = 4663
        self.write_manifest()
        with self.assertRaises(AssertionError):
            self.run_cli()


if __name__ == "__main__":
    unittest.main()
