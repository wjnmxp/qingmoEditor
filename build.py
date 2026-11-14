#!/usr/bin/env python3
"""Build a standalone, locally signed macOS app using the installed Apple SDK."""
from pathlib import Path
import plistlib
import subprocess
from tools.toolchain import swift_command
import shutil

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
APP = BUILD / ".staging" / "清墨.app"
CONTENTS = APP / "Contents"
BUILD.mkdir(exist_ok=True)
(CONTENTS / "MacOS").mkdir(parents=True, exist_ok=True)
(CONTENTS / "Resources").mkdir(parents=True, exist_ok=True)
subprocess.run([*swift_command(), "-O", "-whole-module-optimization", "-module-name", "Qingmo",
                *map(str, sorted((ROOT / "Sources").glob("*.swift"))),
                "-o", str(CONTENTS / "MacOS" / "Qingmo")], check=True)
icon_tool = BUILD / "MakeIcon"
subprocess.run([*swift_command(), str(ROOT / "tools" / "MakeIcon.swift"), "-o", str(icon_tool)], check=True)
subprocess.run([str(icon_tool), str(BUILD / "AppIcon.iconset")], check=True)
subprocess.run(["iconutil", "-c", "icns", str(BUILD / "AppIcon.iconset"),
                "-o", str(CONTENTS / "Resources" / "AppIcon.icns")], check=True)
info = {
    "CFBundleName": "清墨",
    "CFBundleDisplayName": "清墨",
    "CFBundleIdentifier": "net.qingmo.editor",
    "CFBundleExecutable": "Qingmo",
    "CFBundleIconFile": "AppIcon",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "0.4.1",
    "CFBundleVersion": "6",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "清墨 · 本地 Markdown 编辑器",
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundleLocalizations": ["zh-Hans", "en"],
    "CFBundleDocumentTypes": [{
        "CFBundleTypeName": "Markdown 文稿",
        "CFBundleTypeRole": "Editor",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["net.qingmo.markdown", "net.daringfireball.markdown", "public.plain-text"],
        "CFBundleTypeExtensions": ["md", "markdown", "txt", "mdown", "mkd"],
        "NSDocumentClass": "MarkdownDocument"
    }],
    "UTExportedTypeDeclarations": [{
        "UTTypeIdentifier": "net.qingmo.markdown",
        "UTTypeDescription": "Markdown 文稿",
        "UTTypeConformsTo": ["public.plain-text"],
        "UTTypeTagSpecification": {"public.filename-extension": ["md", "markdown", "mdown", "mkd"]}
    }]
}
shutil.copyfile(ROOT / "使用指南.md", CONTENTS / "Resources" / "使用指南.md")
with (CONTENTS / "Info.plist").open("wb") as f:
    plistlib.dump(info, f)
(CONTENTS / "PkgInfo").write_bytes(b"APPL????")
subprocess.run(["codesign", "--force", "--sign", "-", str(APP)], check=True)
print(APP)
