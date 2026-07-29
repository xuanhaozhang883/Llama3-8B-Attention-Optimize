#!/usr/bin/env python3
"""Create and build a Vitis 2025.2 A53 standalone workspace from an XSA.

This script is executed by ``vitis -s``.  Inputs are environment variables so
the same script works from PowerShell and from the Vitis GUI terminal.
Generated workspaces belong under system/generated and are not source assets.
"""

import json
import os
from pathlib import Path
import shutil
import stat
import sys
import traceback

import vitis


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"required environment variable is missing: {name}")
    return value


def remove_readonly(func, path, _exc_info) -> None:
    """Allow recreation of Vitis trees containing read-only vendor headers."""
    os.chmod(path, stat.S_IWRITE)
    func(path)


REPO = Path(__file__).resolve().parents[3]
SYSTEM = REPO / "rk_xczu15eg_f" / "system"
XSA = Path(required_env("RK_VITIS_XSA")).resolve()
WORKSPACE = Path(required_env("RK_VITIS_WORKSPACE")).resolve()
PROFILE = required_env("RK_VITIS_PROFILE")
RECREATE = os.environ.get("RK_VITIS_RECREATE", "0") == "1"
EXTERNAL_SAFE_ROOT = Path(
    os.environ.get(
        "RK_VITIS_SAFE_ROOT",
        str(SYSTEM / "generated" / "vitis_workspace"),
    )
).resolve()

PROFILES = {
    "dma_loopback": {
        "platform": "rk_dma_platform",
        "apps": {
            "ps_ddr_test": [
                SYSTEM / "software" / "ps_ddr_test" / "main.c",
            ],
            "dma_loopback": [
                SYSTEM / "software" / "dma_loopback" / "main.c",
            ],
        },
    },
    "attention_single_gqa": {
        "platform": "rk_attention_platform",
        "apps": {
            "ps_ddr_test": [
                SYSTEM / "software" / "ps_ddr_test" / "main.c",
            ],
            "attention_single_gqa": [
                SYSTEM / "software" / "attention_single_gqa" / "main.c",
                SYSTEM / "software" / "common" / "attention_config.c",
                SYSTEM / "software" / "common" / "attention_config.h",
                SYSTEM / "software" / "common" / "attention_data_provider.c",
                SYSTEM / "software" / "common" / "attention_data_provider.h",
            ],
        },
    },
}


def write_status(status: str, message: str, elf_files=None) -> None:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "status": status,
        "message": message,
        "profile": PROFILE,
        "xsa": str(XSA),
        "workspace": str(WORKSPACE),
        "processor": "psu_cortexa53_0",
        "os": "standalone",
        "simulation_launched": False,
        "hardware_state": "HARDWARE_PENDING",
        "elf_files": elf_files or [],
    }
    (WORKSPACE / "vitis_build_status.json").write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def require_build_success(result, label: str) -> None:
    text = str(result).upper()
    if result is False or any(
        token in text for token in ("FAILURE", "FAILED", "ERROR")
    ):
        raise RuntimeError(f"{label} build failed: {result}")


def main() -> None:
    if PROFILE not in PROFILES:
        raise RuntimeError(
            f"unsupported RK_VITIS_PROFILE '{PROFILE}'; "
            f"choose one of {', '.join(PROFILES)}"
        )
    if not XSA.is_file():
        raise RuntimeError(f"XSA does not exist: {XSA}")
    for sources in PROFILES[PROFILE]["apps"].values():
        for source in sources:
            if not source.is_file():
                raise RuntimeError(f"application source does not exist: {source}")

    if WORKSPACE.exists():
        if not RECREATE:
            raise RuntimeError(
                f"workspace already exists: {WORKSPACE}; use -Recreate explicitly"
            )
        generated_root = (SYSTEM / "generated").resolve()
        if (
            generated_root not in WORKSPACE.parents
            and EXTERNAL_SAFE_ROOT != WORKSPACE
            and EXTERNAL_SAFE_ROOT not in WORKSPACE.parents
        ):
            raise RuntimeError(
                "refusing to recreate workspace outside approved generated "
                f"roots {generated_root} and {EXTERNAL_SAFE_ROOT}: {WORKSPACE}"
            )
        shutil.rmtree(WORKSPACE, onerror=remove_readonly)

    client = vitis.create_client()
    try:
        client.set_workspace(str(WORKSPACE))
        write_status("IN_PROGRESS", "Vitis workspace build started")
        platform_name = PROFILES[PROFILE]["platform"]
        domain_name = "standalone_a53_0"
        platform = client.create_platform_component(
            name=platform_name,
            hw_design=str(XSA),
            domain_name=domain_name,
            cpu="psu_cortexa53_0",
            os="standalone",
        )
        require_build_success(platform.build(), "platform")
        platform_xpfm = client.find_platform_in_repos(platform_name)
        if not platform_xpfm:
            raise RuntimeError(
                f"Vitis did not publish platform '{platform_name}' to the "
                "workspace repository"
            )

        for app_name, sources in PROFILES[PROFILE]["apps"].items():
            component = client.create_app_component(
                name=app_name,
                platform=platform_xpfm,
                domain=domain_name,
                template="empty_application",
            )
            for source in sources:
                component.import_files(
                    from_loc=str(source.parent),
                    files=[source.name],
                    dest_dir_in_cmp="src",
                )
            require_build_success(component.build(), app_name)

        elf_files = []
        for app_name in PROFILES[PROFILE]["apps"]:
            expected_elf = WORKSPACE / app_name / "build" / f"{app_name}.elf"
            if not expected_elf.is_file():
                raise RuntimeError(
                    f"application build returned without ELF: {expected_elf}"
                )
            elf_files.append(str(expected_elf.resolve()))
        write_status("SOFTWARE_PASS", "Vitis applications built", elf_files)
        print(f"RK_VITIS_WORKSPACE_READY={WORKSPACE}")
        for elf in elf_files:
            print(f"RK_VITIS_ELF={elf}")
    finally:
        vitis.dispose()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        try:
            write_status("FAILED", str(exc))
        except Exception:
            pass
        traceback.print_exc()
        sys.exit(1)
