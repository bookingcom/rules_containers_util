#!/usr/bin/env python3
"""End-to-end integration test for Dockerfile parsing, image extraction, and RPM lockfile resolution with dnf5."""

import json
import os
import sqlite3
import subprocess
import sys
import unittest
from pathlib import Path


def find_file(rel_path: str) -> Path:
    runfiles_dir = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR")

    # 1. Direct path check
    p = Path(rel_path)
    if p.is_file():
        return p.resolve()

    # 2. Search inside RUNFILES_DIR / TEST_SRCDIR
    if runfiles_dir:
        rf = Path(runfiles_dir)
        # Direct join with runfiles
        if (rf / rel_path).is_file():
            return (rf / rel_path).resolve()

        # Handle paths starting with bazel-out/.../bin/ or external/
        cleaned = rel_path
        if "bin/" in cleaned:
            cleaned = cleaned.split("bin/", 1)[1]
            if (rf / cleaned).is_file():
                return (rf / cleaned).resolve()
        if cleaned.startswith("external/"):
            cleaned_no_ext = cleaned[len("external/"):]
            if (rf / cleaned_no_ext).is_file():
                return (rf / cleaned_no_ext).resolve()

        # Search inside workspace subdirectories in runfiles (e.g., _main, rules_containers_util+)
        if rf.is_dir():
            for child in rf.iterdir():
                if child.is_dir():
                    if (child / rel_path).is_file():
                        return (child / rel_path).resolve()
                    if (child / Path(rel_path).name).is_file():
                        return (child / Path(rel_path).name).resolve()

        # Fallback: search by exact filename across runfiles
        target_name = Path(rel_path).name
        for root, _, files in os.walk(runfiles_dir):
            if target_name in files:
                candidate = Path(root) / target_name
                if candidate.is_file():
                    return candidate.resolve()

    # 3. Relative to this script's directory
    script_dir = Path(__file__).resolve().parent
    p = script_dir / rel_path
    if p.is_file():
        return p.resolve()

    raise FileNotFoundError(f"Could not locate file: {rel_path} (search root: {runfiles_dir})")


def get_parser_bin() -> Path:
    # 1. Explicit rlocation path
    if "PARSER_RLOCATION" in os.environ:
        try:
            return find_file(os.environ["PARSER_RLOCATION"])
        except FileNotFoundError:
            pass

    # 2. Location path
    if "PARSER_BIN" in os.environ:
        try:
            return find_file(os.environ["PARSER_BIN"])
        except FileNotFoundError:
            pass

    # 3. Well-known candidate paths
    for candidate in [
        "rules_containers_util+/containers/dockerfile_parser",
        "rules_containers_util/containers/dockerfile_parser",
        "containers/dockerfile_parser",
        "cmd/dockerfile_parser/dockerfile_parser_/dockerfile_parser",
        "cmd/dockerfile_parser/dockerfile_parser",
    ]:
        try:
            return find_file(candidate)
        except FileNotFoundError:
            continue

    raise FileNotFoundError("dockerfile_parser binary could not be found")


class E2EOracleLinux10Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parser_bin = get_parser_bin()
        cls.dockerfile_path = (
            find_file(os.environ["DOCKERFILE_RLOCATION"])
            if "DOCKERFILE_RLOCATION" in os.environ
            else find_file("Dockerfile.ol10")
        )
        cls.lock_file_path = (
            find_file(os.environ["LOCK_RLOCATION"])
            if "LOCK_RLOCATION" in os.environ
            else find_file("ol10_curl_git_lock.lock.json")
        )
        cls.rpmdb_path = (
            find_file(os.environ["RPMDB_RLOCATION"])
            if "RPMDB_RLOCATION" in os.environ
            else find_file("ol10_rpmdb.sqlite")
        )
        cls.repo_file_path = (
            find_file(os.environ["REPO_RLOCATION"])
            if "REPO_RLOCATION" in os.environ
            else find_file("oracle-linux-ol10.repo")
        )

        # Determine output directories for capturing artifacts
        cls.undeclared_outputs_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
        cls.artifacts_dir = Path("artifacts")
        cls.artifacts_dir.mkdir(parents=True, exist_ok=True)

    def save_json_artifact(self, name: str, data: dict or list):
        """Saves a JSON artifact to undeclared outputs and local artifacts dir."""
        content = json.dumps(data, indent=2)

        # 1. Local artifacts dir
        dest_local = self.artifacts_dir / name
        dest_local.write_text(content, encoding="utf-8")

        # 2. Bazel undeclared outputs dir (zipped into test.outputs/outputs.zip)
        if self.undeclared_outputs_dir:
            out_path = Path(self.undeclared_outputs_dir) / name
            out_path.write_text(content, encoding="utf-8")

    def test_01_parse_dockerfile_and_identify_packages(self):
        """Parses Dockerfile.ol10 with dockerfile_parser and extracts install arguments."""
        proc = subprocess.run(
            [str(self.parser_bin), str(self.dockerfile_path)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"dockerfile_parser failed: {proc.stderr}",
        )

        layers = json.loads(proc.stdout)
        self.assertIsInstance(layers, list, "Expected layers array")
        self.save_json_artifact("dockerfile_ast.json", layers)

        # Verify base image
        from_layers = [l for l in layers if l["command"] == "FROM"]
        self.assertEqual(len(from_layers), 1)
        base_image = from_layers[0]["value"]
        self.assertIn("oraclelinux:10-slim", base_image)

        # Find RUN instruction with dnf/yum install
        run_layers = [l for l in layers if l["command"] == "RUN"]
        self.assertGreaterEqual(len(run_layers), 1)

        packages = []
        for run_layer in run_layers:
            tokens = run_layer.get("args", [])
            if len(tokens) <= 1 and "value" in run_layer:
                tokens = run_layer["value"].split()

            for i, tok in enumerate(tokens):
                if tok in ("dnf", "yum") and i + 1 < len(tokens):
                    cmd = tokens[i + 1]
                    if cmd in ("install", "in"):
                        pkg_tokens = [
                            t for t in tokens[i + 2 :] if not t.startswith("-")
                        ]
                        packages.extend(pkg_tokens)

        print(f"Discovered packages to install: {packages}")
        self.assertEqual(
            packages,
            ["curl", "git"],
            f"Expected packages ['curl', 'git'], got {packages}",
        )

    def test_02_verify_extracted_rpm_environment(self):
        """Verifies rpmdb and repo configs extracted from the OL10 image."""
        self.assertTrue(
            self.rpmdb_path.exists(),
            f"Extracted rpmdb not found: {self.rpmdb_path}",
        )
        self.assertGreater(
            self.rpmdb_path.stat().st_size,
            0,
            "rpmdb.sqlite is empty",
        )

        # Validate SQLite header and query package table
        with open(self.rpmdb_path, "rb") as f:
            header = f.read(16)
        self.assertEqual(
            header,
            b"SQLite format 3\x00",
            "Extracted rpmdb is not a valid SQLite 3 database",
        )

        conn = sqlite3.connect(str(self.rpmdb_path))
        cursor = conn.cursor()
        cursor.execute("SELECT count(*) FROM Packages")
        pkg_count = cursor.fetchone()[0]
        conn.close()
        self.assertGreater(
            pkg_count,
            0,
            f"Base rpmdb should contain packages, found {pkg_count}",
        )
        print(f"Base OL10 rpmdb package count: {pkg_count}")

        # Verify repo file
        self.assertTrue(
            self.repo_file_path.exists(),
            f"Extracted repo file not found: {self.repo_file_path}",
        )
        repo_content = self.repo_file_path.read_text(encoding="utf-8")
        self.assertIn("[ol10_baseos_latest]", repo_content)
        self.assertIn("[ol10_appstream]", repo_content)

    def test_03_verify_generated_lockfile(self):
        """Verifies that the generated lockfile resolves curl and git with all dependencies."""
        self.assertTrue(
            self.lock_file_path.exists(),
            f"Lockfile not found: {self.lock_file_path}",
        )

        with open(self.lock_file_path, "r", encoding="utf-8") as f:
            lock_data = json.load(f)

        self.save_json_artifact("ol10_curl_git_lock.lock.json", lock_data)

        self.assertEqual(lock_data.get("version"), 1)
        self.assertEqual(lock_data.get("requested"), ["curl", "git"])

        packages = lock_data.get("packages", [])
        self.assertGreater(
            len(packages),
            0,
            "Lockfile contains no packages",
        )

        pkg_names = {p["name"] for p in packages}
        self.assertIn(
            "curl",
            pkg_names,
            f"Expected 'curl' in locked packages, found: {pkg_names}",
        )
        self.assertIn(
            "git",
            pkg_names,
            f"Expected 'git' in locked packages, found: {pkg_names}",
        )

        for p in packages:
            name = p["name"]
            self.assertTrue(p.get("version"), f"Package {name} missing version")
            self.assertIn(
                p.get("arch"),
                ("x86_64", "noarch"),
                f"Package {name} unexpected arch: {p.get('arch')}",
            )
            url = p.get("url", "")
            self.assertTrue(
                url.startswith("https://yum.oracle.com/"),
                f"Package {name} invalid url: {url}",
            )
            integrity = p.get("integrity", "")
            self.assertTrue(
                integrity.startswith("sha256-"),
                f"Package {name} invalid SRI integrity: {integrity}",
            )
            checksum = p.get("checksum", "")
            self.assertEqual(
                len(checksum),
                64,
                f"Package {name} invalid 64-char sha256 checksum: {checksum}",
            )

        summary = {
            "status": "success",
            "base_image": "oraclelinux:10-slim",
            "requested_packages": ["curl", "git"],
            "total_packages_resolved": len(packages),
            "packages": sorted(list(pkg_names)),
        }
        self.save_json_artifact("e2e_summary.json", summary)
        print(
            f"Successfully resolved and validated {len(packages)} packages for curl and git!"
        )


if __name__ == "__main__":
    unittest.main()
