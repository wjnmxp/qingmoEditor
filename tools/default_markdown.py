#!/usr/bin/env python3
"""Inspect or explicitly set Qingmo as the default Markdown application."""
from pathlib import Path
import datetime
import subprocess
import sys
from toolchain import swift_command

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
mode = sys.argv[1] if len(sys.argv) > 1 else "--inspect"
if mode not in ("--inspect", "--apply"):
    raise SystemExit("Usage: python3 tools/default_markdown.py [--inspect|--apply] [sample.md ...]")
binary = BUILD / "DefaultMarkdown"
subprocess.run([*swift_command(), str(ROOT / "tools/DefaultMarkdown.swift"), "-o", str(binary)], check=True)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
report = BUILD / "backups" / ("default-markdown-" + stamp + ".json")
samples = sys.argv[2:] or [str(ROOT / "README.md")]
subprocess.run([str(binary), mode, str(report), *samples], check=True)
