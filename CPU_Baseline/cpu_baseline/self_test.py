from __future__ import annotations

import tempfile
from pathlib import Path

from .config import BenchmarkConfig
from .run_benchmark import main as benchmark_main


def test_config_validation() -> None:
    config = BenchmarkConfig(q_heads=4, kv_heads=1, seq_len=16, head_dim=128, repeat=1)
    config.validate()


def test_benchmark_cli_smoke() -> None:
    import sys

    with tempfile.TemporaryDirectory() as tmp:
        old_argv = sys.argv[:]
        try:
            sys.argv = [
                "run_benchmark",
                "--preset",
                "small",
                "--repeat",
                "1",
                "--warmup",
                "0",
                "--out",
                tmp,
            ]
            benchmark_main()
        finally:
            sys.argv = old_argv

        out_dir = Path(tmp)
        assert (out_dir / "cpu_perf_metrics.json").exists()
        assert (out_dir / "summary.csv").exists()
        assert (out_dir / "report.txt").exists()


def main() -> None:
    test_config_validation()
    print("PASS test_config_validation")
    test_benchmark_cli_smoke()
    print("PASS test_benchmark_cli_smoke")
    print("ALL CPU BASELINE SELF TESTS PASSED")


if __name__ == "__main__":
    main()
