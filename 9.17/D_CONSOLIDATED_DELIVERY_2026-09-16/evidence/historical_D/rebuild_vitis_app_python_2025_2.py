import os
import sys
import traceback

import vitis


WORKSPACE = r"D:\fv314py_0913"
SOURCE_DIR = (
    r"C:\Users\23858\xwechat_files\wxid_704fehcdj58l22_8fda\msg\file\2026-09"
    r"\03_work_v314_causal_bypass\workspace\Llama3-8B-Attention-Optimize-ABL-v314"
    r"\vitis\src"
)


client = None
try:
    client = vitis.create_client(workspace=WORKSPACE)
    client.set_workspace(WORKSPACE)
    app = client.get_component(name="fpt_attention_test_py")
    if app is None:
        raise RuntimeError("fpt_attention_test_py component was not found")
    app.import_files(
        from_loc=SOURCE_DIR,
        files=["fpt_attention_board_test.c", "fpt_golden_vectors.h"],
        dest_dir_in_cmp="src",
    )
    app.build()

    matches = []
    for directory, _, files in os.walk(os.path.join(WORKSPACE, "fpt_attention_test_py")):
        for filename in files:
            if filename.lower().endswith(".elf"):
                matches.append(os.path.join(directory, filename))
    if not matches:
        raise RuntimeError("Application rebuild completed without producing an ELF")
    for elf_file in sorted(matches):
        print(f"ELF={elf_file}")
    print("VITIS_APP_REBUILD_PASS")
except Exception:
    traceback.print_exc()
    print("VITIS_APP_REBUILD_FAIL")
    sys.exit(1)
finally:
    if client is not None:
        vitis.dispose()
