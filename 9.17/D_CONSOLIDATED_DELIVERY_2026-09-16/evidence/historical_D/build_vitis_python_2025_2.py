import os
import sys
import traceback

import vitis


WORKSPACE = r"D:\fv314py_0913"
XSA = (
    r"C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09"
    r"\03_work_v314_causal_bypass\workspace\D\output\BOARD_VALIDATION_2026-09-13"
    r"\artifacts\archive_extract\export\fpt_attention_board_v314_qk4_causal_bypass.xsa"
)
SOURCE_DIR = (
    r"C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09"
    r"\03_work_v314_causal_bypass\workspace\Llama3-8B-Attention-Optimize-ABL-v314"
    r"\vitis\src"
)


def find_elf(root):
    matches = []
    for directory, _, files in os.walk(root):
        for filename in files:
            if filename.lower().endswith(".elf"):
                matches.append(os.path.join(directory, filename))
    return sorted(matches)


client = None
try:
    print(f"WORKSPACE={WORKSPACE}")
    print(f"XSA={XSA}")
    client = vitis.create_client(workspace=WORKSPACE)
    client.set_workspace(WORKSPACE)

    platform = client.create_platform_component(
        name="fpt_attention_platform_py",
        hw_design=XSA,
        os="standalone",
        cpu="psu_cortexa53_0",
        domain_name="standalone_domain",
        no_boot_bsp=True,
    )
    platform.report()
    platform.build()

    platform_xpfm = client.find_platform_in_repos("fpt_attention_platform_py")
    if not platform_xpfm:
        raise RuntimeError("Generated platform was not found in platform repositories")
    print(f"PLATFORM_XPFM={platform_xpfm}")

    app = client.create_app_component(
        name="fpt_attention_test_py",
        platform=platform_xpfm,
        domain="standalone_domain",
        template="empty_application",
    )
    app.import_files(
        from_loc=SOURCE_DIR,
        files=["fpt_attention_board_test.c", "fpt_golden_vectors.h"],
        dest_dir_in_cmp="src",
    )
    app.report()
    app.build()

    elf_files = find_elf(WORKSPACE)
    if not elf_files:
        raise RuntimeError("Vitis build completed without producing an ELF")
    for elf_file in elf_files:
        print(f"ELF={elf_file}")
    print("VITIS_PYTHON_BUILD_PASS")
except Exception:
    traceback.print_exc()
    print("VITIS_PYTHON_BUILD_FAIL")
    sys.exit(1)
finally:
    if client is not None:
        vitis.dispose()
