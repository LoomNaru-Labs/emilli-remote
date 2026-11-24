"""Sets the program's version everywhere the build reads it (REMOTE-EASY-4): Cargo.toml and
libs/portable/Cargo.toml, their two entries in Cargo.lock, and flutter/pubspec.yaml (the build
number after "+" is kept). The CI test builds use it to make a newer test version of the same code.
Usage: python .github/scripts/set-version.py 1.5.6"""

import re
import sys

version = sys.argv[1]
if not re.fullmatch(r"\d+\.\d+\.\d+(\.\d+)?", version):
    sys.exit(f"not a version: {version}")


def edit(path: str, pattern: str, repl: str, count: int) -> None:
    text = open(path, encoding="utf-8").read()
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if n != count:
        sys.exit(f"{path}: {n} replacements, expected {count}")
    open(path, "w", encoding="utf-8", newline="\n").write(new)
    print(f"{path}: version {version}")


edit("Cargo.toml", r'^version = "[^"]+"', f'version = "{version}"', 1)
edit("libs/portable/Cargo.toml", r'^version = "[^"]+"', f'version = "{version}"', 1)
edit(
    "Cargo.lock",
    r'^(name = "(?:rustdesk|rustdesk-portable-packer)"\nversion = )"[^"]+"',
    rf'\g<1>"{version}"',
    2,
)
edit("flutter/pubspec.yaml", r"^version: [^+\n]+", f"version: {version}", 1)
