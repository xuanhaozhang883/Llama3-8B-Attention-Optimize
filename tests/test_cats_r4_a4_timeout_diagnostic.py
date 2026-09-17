import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON = Path(
    r"C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
)
SCRIPT = ROOT / "python" / "cats_r4_a4_timeout_diagnostic.py"


class A4TimeoutDiagnosticTests(unittest.TestCase):
    def test_cli_saves_last_primary_and_detail_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stdout = root / "stdout.log"
            stderr = root / "stderr.log"
            output = root / "timeout_diagnostic.json"
            stdout.write_text(
                "PROGRESS heartbeat=100000 jobs_counter=31 rows=16 scores=136 "
                "releases=8 final=7 outputs=32 owner=1 client=1 qk=0 ctx=2 "
                "score=1/1 raw=1 b2=0/1/2\n"
                "PROGRESS heartbeat=200000 jobs_counter=63 rows=48 scores=1176 "
                "releases=32 final=31 outputs=128 owner=5 client=2 qk=1 ctx=7 "
                "score=1/0 raw=0 b2=2/1/0\n"
                "PROGRESS a2 fmt=1/0 keyblock=3 opened=1 rowopen=1/0 "
                "block=1/0 asm=5 hs=1/0 release=1/0\n",
                encoding="utf-8",
            )
            stderr.write_text("simulator still active\n", encoding="utf-8")

            completed = subprocess.run(
                [
                    str(PYTHON),
                    str(SCRIPT),
                    "--stdout",
                    str(stdout),
                    "--stderr",
                    str(stderr),
                    "--output",
                    str(output),
                    "--mode",
                    "1",
                    "--seed",
                    "19",
                    "--clusters",
                    "2",
                    "--cluster-id",
                    "1",
                    "--job-count",
                    "128",
                    "--timeout-seconds",
                    "30",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            diagnostic = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(diagnostic["schema"], "cats-r4-a4-timeout-diagnostic-v1")
            self.assertEqual(diagnostic["status"], "timeout_with_progress")
            self.assertEqual(diagnostic["configuration"]["seed"], 19)
            self.assertEqual(diagnostic["last_progress"]["heartbeat"], 200000)
            self.assertEqual(diagnostic["last_progress"]["jobs_counter"], 63)
            self.assertEqual(diagnostic["last_progress"]["owner"], "5")
            self.assertEqual(diagnostic["last_progress"]["client"], 2)
            self.assertEqual(diagnostic["last_progress"]["qk"], 1)
            self.assertEqual(diagnostic["last_progress"]["ctx"], 7)
            self.assertEqual(diagnostic["last_detail"]["asm"], "5")
            self.assertEqual(diagnostic["last_detail"]["release"], "1/0")
            self.assertRegex(diagnostic["stdout_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(diagnostic["stderr_sha256"], r"^[0-9a-f]{64}$")

    def test_cli_fails_closed_when_no_progress_exists(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stdout = root / "stdout.log"
            stderr = root / "stderr.log"
            output = root / "timeout_diagnostic.json"
            stdout.write_text("compile completed\n", encoding="utf-8")
            stderr.write_text("", encoding="utf-8")

            completed = subprocess.run(
                [
                    str(PYTHON),
                    str(SCRIPT),
                    "--stdout",
                    str(stdout),
                    "--stderr",
                    str(stderr),
                    "--output",
                    str(output),
                    "--mode",
                    "0",
                    "--seed",
                    "7",
                    "--clusters",
                    "2",
                    "--cluster-id",
                    "0",
                    "--job-count",
                    "128",
                    "--timeout-seconds",
                    "30",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            diagnostic = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(diagnostic["status"], "timeout_without_progress")
            self.assertIsNone(diagnostic["last_progress"])
            self.assertIsNone(diagnostic["last_detail"])

    def test_compute_array_runner_writes_diagnostic_on_wall_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "runner_evidence"
            environment = os.environ.copy()
            path_value = next(
                value for key, value in environment.items() if key.lower() == "path"
            )
            for key in [key for key in environment if key.lower() == "path"]:
                del environment[key]
            environment["Path"] = path_value
            completed = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(ROOT / "tests" / "run_cats_r4_a4_compute_array_iverilog.ps1"),
                    "-IcarusRoot",
                    r"C:\Software\iverilog",
                    "-Mode",
                    "0",
                    "-Seed",
                    "7",
                    "-TimeoutSeconds",
                    "1",
                    "-OutputRoot",
                    str(output),
                    "-JobCount",
                    "256",
                    "-Clusters",
                    "1",
                    "-ClusterId",
                    "0",
                    "-PythonExe",
                    str(PYTHON),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
                timeout=60,
            )

            self.assertNotEqual(completed.returncode, 0)
            diagnostic_path = output / "timeout_diagnostic.json"
            self.assertTrue(diagnostic_path.is_file(), completed.stderr)
            diagnostic = json.loads(diagnostic_path.read_text(encoding="utf-8"))
            self.assertEqual(diagnostic["configuration"]["timeout_seconds"], 1)
            self.assertEqual(diagnostic["configuration"]["job_count"], 256)
            self.assertIn(
                diagnostic["status"],
                {"timeout_with_progress", "timeout_without_progress"},
            )


if __name__ == "__main__":
    unittest.main()
