"""Restore missing SDK files into a private Clang VFS view, never the SDK."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import urllib.request
import urllib.error
import http.client
import time
from toolchain import write_sdk_overlay

ROOT = Path(__file__).resolve().parents[1]
SDK = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.4.sdk")
REV = "22c08201005fe5240a662b79c9e11e4c48ed38a2"
BASE = "https://api.github.com/repos/alexey-lysiuk/macos-sdk"
RAW = "https://raw.githubusercontent.com/alexey-lysiuk/macos-sdk/" + REV + "/MacOSX26.4.sdk/"
OUTPUT = ROOT / "build/SDKHeaders"
OUTPUT.mkdir(parents=True, exist_ok=True)

def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Qingmo-local-build"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return response.read()
        except (http.client.IncompleteRead, urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)

root = json.loads(get(BASE + "/contents/MacOSX26.4.sdk?ref=" + REV))
entries = []
for name in ["System", "usr"]:
    subtree = next(x for x in root if x["name"] == name)
    tree = json.loads(get(BASE + "/git/trees/" + subtree["sha"] + "?recursive=1"))
    if tree.get("truncated"):
        raise RuntimeError("SDK inventory was truncated")
    entries.extend({"path": name + "/" + x["path"], "sha": x["sha"]} for x in tree["tree"]
                   if x["type"] == "blob" and x.get("mode") != "120000"
                   and ((x["path"].endswith(".h") and "trans" in Path(x["path"]).name.lower())
                        or "CoreTransferable.framework/" in x["path"])
                   and not (SDK / name / x["path"]).exists())

def download(entry):
    relative = entry["path"]
    path = OUTPUT / relative
    data = path.read_bytes() if path.exists() else get(RAW + relative)
    digest = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if digest != entry["sha"]:
        raise RuntimeError("SDK source integrity mismatch: " + relative)
    path = OUTPUT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {"sdk_path": relative, "source": RAW + relative,
            "git_blob": digest, "sha256": hashlib.sha256(data).hexdigest(),
            "local": str(path.relative_to(ROOT / "build"))}

print("Preparing", len(entries), "missing SDK files", flush=True)
with ThreadPoolExecutor(max_workers=4) as executor:
    records = list(executor.map(download, entries))

# Keep the manifest portable; generate the compiler's concrete paths at its boundary.
(OUTPUT / "manifest.json").write_text(json.dumps(records, indent=2))
write_sdk_overlay(SDK)
print("Prepared", len(records), "original SDK files in project-local overlay", flush=True)
