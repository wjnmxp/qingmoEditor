#!/usr/bin/env python3
"""Install one Qingmo copy; keep backups as ZIP files that Launch Services cannot register."""
from pathlib import Path
import datetime
import hashlib
import plistlib
import shutil
import subprocess
import zipfile
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
SOURCE = BUILD / ".staging" / "清墨.app"
TARGET = Path.home() / "Applications" / "清墨.app"
BACKUPS = BUILD / "backups"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BUNDLE_ID = "net.qingmo.editor"

def own_bundle(path):
    info = path / "Contents" / "Info.plist"
    return info.is_file() and plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") == BUNDLE_ID

def archive(path):
    BACKUPS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    destination = BACKUPS / (path.name + "-" + stamp + ".zip")
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(path), str(destination)], check=True)
    with zipfile.ZipFile(destination) as saved:
        if saved.testzip() is not None:
            raise RuntimeError("Backup ZIP failed verification: " + str(destination))
    # Use macOS's archive reader for Unicode paths and resource-fork metadata.
    with tempfile.TemporaryDirectory(prefix="verify-qingmo-", dir=BUILD) as temporary:
        subprocess.run(["ditto", "-x", "-k", str(destination), temporary], check=True)
        restored = Path(temporary) / path.name
        for file in path.rglob("*"):
            if file.is_file() and not file.is_symlink():
                copy = restored / file.relative_to(path)
                if not copy.is_file() or hashlib.sha256(copy.read_bytes()).digest() != hashlib.sha256(file.read_bytes()).digest():
                    raise RuntimeError("Backup content mismatch: " + str(file))
                if file.stat().st_mode & 0o111 != copy.stat().st_mode & 0o111:
                    raise RuntimeError("Backup executable permissions mismatch: " + str(file))
    return destination

def unregister(path):
    result = subprocess.run([LSREGISTER, "-u", str(path)], capture_output=True, text=True)
    # -10814 is kLSApplicationNotFoundErr: this path has no registration to remove.
    if result.returncode and "-10814" not in result.stdout + result.stderr:
        raise RuntimeError("Cannot unregister " + str(path) + ": " + result.stdout + result.stderr)

def cleanup_history():
    # Only remove verified Qingmo artifacts in this project's build directory.
    historical = [BUILD / "清墨.app"]
    if BACKUPS.exists():
        historical.extend(p for p in BACKUPS.iterdir() if p.is_dir())
    for path in historical:
        if not own_bundle(path):
            continue
        backup = archive(path)
        unregister(path)
        shutil.rmtree(path)
        print("Historical app archived and unregistered:", path, "->", backup.name)
    unregister(SOURCE)


def install():
    if not own_bundle(SOURCE):
        raise SystemExit("Run python3 build.py first.")
    running = subprocess.run(["pgrep", "-x", "Qingmo"], capture_output=True)
    if running.returncode == 0:
        raise SystemExit("Please save documents and quit Qingmo before installing.")
    if running.returncode != 1:
        raise SystemExit("Could not verify whether Qingmo is running; installation stopped.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(SOURCE)], check=True)
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    if TARGET.exists() and not own_bundle(TARGET):
        raise SystemExit("Refusing to replace an unrelated application.")

    # Prepare the replacement fully before touching the installed copy.
    staged = TARGET.parent / ".qingmo-install.app"
    if staged.exists():
        raise SystemExit("An earlier installation staging directory needs inspection: " + str(staged))
    shutil.copytree(SOURCE, staged)
    backup = None
    try:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
        if TARGET.exists():
            backup = archive(TARGET)
            unregister(TARGET)
            shutil.rmtree(TARGET)
            print("Previous version archived:", backup)
        staged.rename(TARGET)
    except Exception:
        if not TARGET.exists() and backup is not None:
            subprocess.run(["ditto", "-x", "-k", str(backup), str(TARGET.parent)], check=True)
            subprocess.run([LSREGISTER, "-f", str(TARGET)], check=True)
        if staged.exists():
            shutil.rmtree(staged)
        raise
    subprocess.run([LSREGISTER, "-f", str(TARGET)], check=True)

    cleanup_history()
    print("Installed:", TARGET)

if __name__ == "__main__":
    if sys.argv[1:] == ["--cleanup-history"]:
        cleanup_history()
    elif len(sys.argv) == 1:
        install()
    else:
        raise SystemExit("Usage: python3 tools/install.py [--cleanup-history]")
