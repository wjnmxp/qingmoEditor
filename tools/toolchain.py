"""Resolve the local Apple toolchain without changing the system installation."""
from pathlib import Path
import os
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"

def write_sdk_overlay(sdk):
    """Resolve project-relative SDK evidence into the absolute paths Swift requires."""
    manifest = BUILD / "SDKHeaders" / "manifest.json"
    if not manifest.exists():
        raise RuntimeError("The local SDK is incomplete. Run python3 tools/prepare_sdk.py first.")
    roots = {}
    for entry in json.loads(manifest.read_text()):
        source = BUILD / entry["local"]
        if not source.is_file():
            raise RuntimeError("Missing project-local SDK header: " + str(source))
        path = sdk / entry["sdk_path"]
        roots[str(path)] = str(source)
        roots[str(path.resolve())] = str(source)
        aliases = {str(path)}
        for _ in range(str(path).count("/Versions/")):
            aliases.update(re.sub(r"/Versions/[^/]+/", "/", value, count=1) for value in list(aliases))
        for alias in aliases:
            roots[alias] = str(source)
    overlay = BUILD / "sdk-overlay.json"
    encoded = json.dumps({"version": 0, "use-external-names": False,
                          "roots": [{"type": "file", "name": name, "external-contents": source}
                                    for name, source in sorted(roots.items())]}, indent=2)
    if not overlay.exists() or overlay.read_text() != encoded:
        overlay.write_text(encoded)
    return overlay


def swift_command():
    BUILD.mkdir(exist_ok=True)
    sdk = Path(os.environ.get("QINGMO_SDK") or
               subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()).resolve()
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    command = [compiler, "-swift-version", "5", "-sdk", str(sdk),
               "-target", "arm64-apple-macosx13.0",
               "-module-cache-path", str(BUILD / ("ModuleCache-" + sdk.name))]
    # A private VFS overlay can supply files absent from a damaged local SDK.
    missing = sdk / "usr/include/_types/_wctrans_t.h"
    if not missing.exists():
        overlay = write_sdk_overlay(sdk)
        command.extend(["-vfsoverlay", str(overlay), "-Xcc", "-ivfsoverlay", "-Xcc", str(overlay)])
    return command
