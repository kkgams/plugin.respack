"""Emit clangd commands from Make's compiler, flags and source list."""
import json
import os
from pathlib import Path
import shlex
import shutil
import sys

command = shlex.split(sys.argv[1])
compiler = shutil.which(command[0])
if compiler is None:
    raise SystemExit(f"Compiler not found: {command[0]}; enter nix develop first")
command[0] = compiler
arguments = sys.argv[2:]
separator = arguments.index("--")
flags, sources = arguments[:separator], arguments[separator + 1:]
sysroot = Path(os.environ["WASI_SYSROOT"])
if not sysroot.is_dir():
    raise SystemExit(f"Missing WASI sysroot: {sysroot}")
# clangd does not query the WASI driver by default; pass its target and sysroot.
json.dump([
    {
        "directory": str(Path.cwd()),
        "file": source,
        "arguments": [*command, "--target=wasm32-wasip2", f"--sysroot={sysroot}",
                      *flags, "-c", source],
    }
    for source in sources
], sys.stdout, indent=2)
print()
