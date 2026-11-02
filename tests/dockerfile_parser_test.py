import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


def find_file(rel_path: str) -> Path:
    # Check TEST_SRCDIR first if running under bazel test
    test_srcdir = os.environ.get("TEST_SRCDIR")
    test_workspace = os.environ.get("TEST_WORKSPACE", "_main")
    if test_srcdir:
        candidates = [
            Path(test_srcdir) / test_workspace / rel_path,
            Path(test_srcdir) / "rules_containers_util" / rel_path,
            Path(test_srcdir) / rel_path,
        ]
        for c in candidates:
            if c.exists():
                return c.resolve()

    # Check relative to cwd
    p = Path(rel_path)
    if p.exists():
        return p.resolve()

    # Check relative to repo root (test file is in tests/)
    repo_root = Path(__file__).resolve().parent.parent
    p = repo_root / rel_path
    if p.exists():
        return p.resolve()

    raise FileNotFoundError(f"Could not locate file: {rel_path}")


def get_parser_bin() -> Path:
    if "PARSER_BIN" in os.environ:
        p = Path(os.environ["PARSER_BIN"])
        if p.exists():
            return p.resolve()
        # Might be relative to runfiles
        try:
            return find_file(os.environ["PARSER_BIN"])
        except FileNotFoundError:
            pass

    # Standard locations
    for candidate in [
        "containers/dockerfile_parser",
        "cmd/dockerfile_parser/dockerfile_parser_/dockerfile_parser",
        "cmd/dockerfile_parser/dockerfile_parser",
    ]:
        try:
            return find_file(candidate)
        except FileNotFoundError:
            continue

    raise FileNotFoundError("dockerfile_parser binary could not be found")


class DockerfileParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parser_bin = get_parser_bin()
        cls.testdata_dir = find_file("tests/testdata")

    def run_parser(self, dockerfile_path: Path):
        self.assertTrue(
            dockerfile_path.exists(), f"Dockerfile not found: {dockerfile_path}"
        )
        proc = subprocess.run(
            [str(self.parser_bin), str(dockerfile_path)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            proc.returncode,
            0,
            f"Parser failed with exit code {proc.returncode}.\nStderr: {proc.stderr}",
        )
        data = json.loads(proc.stdout)
        self.assertIsInstance(
            data, list, "Expected output to be a top-level JSON array of layers"
        )
        return data

    def test_basic_dockerfile(self):
        layers = self.run_parser(self.testdata_dir / "Dockerfile.basic")
        self.assertGreater(len(layers), 0)

        commands = [layer["command"] for layer in layers]
        expected_commands = [
            "FROM",
            "LABEL",
            "WORKDIR",
            "COPY",
            "RUN",
            "EXPOSE",
            "ENTRYPOINT",
        ]
        self.assertEqual(commands, expected_commands)

        # Stage checks
        for layer in layers:
            self.assertEqual(layer["stage"], 0)
            self.assertGreater(layer["start_line"], 0)
            self.assertGreaterEqual(layer["end_line"], layer["start_line"])

        # RUN shell_ast check
        run_layers = [l for l in layers if l["command"] == "RUN"]
        self.assertEqual(len(run_layers), 1)
        run_layer = run_layers[0]
        self.assertIn("shell_ast", run_layer)
        self.assertIsNotNone(run_layer["shell_ast"])
        self.assertIn("children", run_layer["shell_ast"])
        self.assertGreater(len(run_layer["shell_ast"]["children"]), 0)

    def test_multistage_dockerfile(self):
        layers = self.run_parser(self.testdata_dir / "Dockerfile.multistage")

        # Must have stage 0 (builder) and stage 1 (runtime)
        stage0_layers = [l for l in layers if l["stage"] == 0]
        stage1_layers = [l for l in layers if l["stage"] == 1]

        self.assertGreater(len(stage0_layers), 0)
        self.assertGreater(len(stage1_layers), 0)

        # Stage 0 name should be builder
        self.assertEqual(stage0_layers[0]["command"], "FROM")
        self.assertEqual(stage0_layers[0]["stage_name"], "builder")

        # Stage 1 name should be runtime
        self.assertEqual(stage1_layers[0]["command"], "FROM")
        self.assertEqual(stage1_layers[0]["stage_name"], "runtime")

        # COPY in stage 1 should contain --from=builder flag
        copy_layers = [
            l
            for l in stage1_layers
            if l["command"] == "COPY" and "--from=builder" in l.get("flags", [])
        ]
        self.assertEqual(
            len(copy_layers),
            1,
            "Expected COPY --from=builder instruction in stage 1",
        )

        # RUN in stage 0 should have shell_ast
        builder_run = [l for l in stage0_layers if l["command"] == "RUN"][0]
        self.assertIsNotNone(builder_run.get("shell_ast"))

    def test_heredoc_dockerfile(self):
        layers = self.run_parser(self.testdata_dir / "Dockerfile.heredoc")
        self.assertEqual(len(layers), 2)
        self.assertEqual(layers[0]["command"], "FROM")

        run_layer = layers[1]
        self.assertEqual(run_layer["command"], "RUN")
        self.assertIn("heredocs", run_layer)
        self.assertGreater(len(run_layer["heredocs"]), 0)

        # The heredoc text should contain apt-get update
        heredoc_text = "\n".join(run_layer["heredocs"])
        self.assertIn("apt-get update", heredoc_text)

        # Shell AST must be parsed from the heredoc content
        self.assertIsNotNone(run_layer.get("shell_ast"))
        children = run_layer["shell_ast"].get("children", [])
        self.assertGreaterEqual(
            len(children),
            2,
            "Expected multiple shell statements in heredoc RUN AST",
        )

    def test_complex_run_dockerfile(self):
        layers = self.run_parser(self.testdata_dir / "Dockerfile.complex_run")
        run_layers = [l for l in layers if l["command"] == "RUN"]
        self.assertEqual(len(run_layers), 1)

        run_layer = run_layers[0]
        self.assertIsNotNone(run_layer.get("shell_ast"))
        children = run_layer["shell_ast"].get("children", [])
        self.assertGreater(
            len(children),
            0,
            "Expected parsed children in complex RUN shell_ast",
        )

        # Check types of nodes in shell_ast
        node_types = set()

        def collect_types(node):
            if not isinstance(node, dict):
                return
            if "type" in node:
                node_types.add(node["type"])
            for child in node.get("children", []):
                collect_types(child)

        collect_types(run_layer["shell_ast"])
        # Should contain binary commands (&& / ||) and/or statements
        self.assertTrue(
            any(t in node_types for t in ["BinaryCmd", "IfClause", "Subshell"]),
            f"Expected complex control structures in AST, found: {node_types}",
        )

    def test_metadata_dockerfile(self):
        layers = self.run_parser(self.testdata_dir / "Dockerfile.metadata")
        cmd_map = {l["command"]: l for l in layers}

        self.assertIn("ARG", cmd_map)
        self.assertIn("ENV", cmd_map)
        self.assertIn("LABEL", cmd_map)
        self.assertIn("VOLUME", cmd_map)
        self.assertIn("EXPOSE", cmd_map)
        self.assertIn("WORKDIR", cmd_map)
        self.assertIn("USER", cmd_map)

        # Check ARG value
        arg_layers = [l for l in layers if l["command"] == "ARG"]
        self.assertGreaterEqual(len(arg_layers), 2)
        arg_names = [l["args"][0] for l in arg_layers if l.get("args")]
        self.assertTrue(any("APP_VERSION" in a for a in arg_names))


if __name__ == "__main__":
    unittest.main()
