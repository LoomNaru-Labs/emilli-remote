#!/usr/bin/env python3
"""REMOTE-EASY-3E: no text of the Windows program names the software Emilli Remote is built on,
except the open-source notice (About > Open-source notice; keys starting with emilli-oss-notice).

Checked here, from the source:
  1. every text of every language table (and every key, shown when a table has no text), after
     the program's own rule: the regular expression BASE_NAME in src/emilli.rs is read from that
     file and applied the way emilli::without_base_name applies it;
  2. every string in the Dart interface code that is not a translation key;
  3. every string in the Rust code outside the language tables, comments, log lines and tests.
A string that names the base software but is never shown on Windows is listed in ALLOWED below
with the reason; anything else fails. The pictures of every page (OCR) and the installed state
are checked on a Windows runner by windows-easy/names-check.ps1 in the Setup workflow.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
NAME = re.compile(r"rust\s*desk|purslane", re.I)
URL = re.compile(r"https?://\S+", re.I)
NOTICE = "emilli-oss-notice"

# Strings with a space or web addresses: (path, regular expression the string must match, reason).
ALLOWED = [
    ("src/lang/en.rs", r"^https://rustdesk\.com/docs/en/client/mac/#enable-permissions$", "macOS help link (doc_mac_permission), not shown on Windows"),
    ("src/lang/en.rs", r"^https://rustdesk\.com/docs/en/client/linux/#x11-required$", "Linux help link (doc_fix_wayland), not shown on Windows"),
    ("flutter/lib/desktop/pages/desktop_home_page.dart", r"^https://rustdesk\.com/docs/en/client/linux/", "Linux help links, shown only on Linux"),
    ("flutter/lib/common.dart", r"^Start closing RustDesk\.\.\.$", "debug log line"),
    ("src/client.rs", r"^https://rustdesk\.com/docs/en/manual/linux/", "Linux help link"),
    ("src/clipboard.rs", r"^RustDesk placeholder to clear the file clipboard$", "Linux KDE only"),
    ("src/common.rs", r"^Update URL is not a RustDesk release tag URL: \{\}$", "update check (off in this build)"),
    ("src/common.rs", r"^https://admin\.rustdesk\.com$", "default account server when none is set; the Setup sets ours"),
    ("src/ipc/drm.rs", r"^RustDesk DRM display wake$", "Linux only"),
    ("src/server/dbus.rs", r"^RustDesk DBus Error", "Linux only"),
    ("src/virtual_display_manager.rs", r"^RustDeskIddDriver Device", "device of a virtual display driver this build does not ship"),
    ("src/platform/windows.rs", r"RuntimeBroker_rustdesk\.exe|librustdesk\.dll|RustDeskPrinterDriver", "removes the files of 1.5.3 and older on upgrade"),
    ("src/platform/windows", r"%RUSTDESK_\w+%|RUSTDESK_\w+=", "variable inside an install script (internal)"),
    ("src/whiteboard/linux.rs", r"^RustDesk whiteboard$", "Linux only"),
    ("src/whiteboard/macos.rs", r"^RustDesk whiteboard$", "macOS only"),
]
# Language keys whose text is a web address of the base software's documentation.
LANG_ALLOWED = {
    "doc_mac_permission": "macOS help link, not shown on Windows",
    "doc_fix_wayland": "Linux help link, not shown on Windows",
}
# Whole files or folders that are not part of the Windows program's visible text.
ALLOWED_PATHS = [
    (r"^flutter/lib/web/", "web client, not part of the Windows program"),
    (r"^flutter/lib/mobile/pages/|^flutter/lib/mobile/widgets/android_", "Android only"),
    (r"linux|wayland|x11|uinput|rdp_input|/dbus\.rs$|/drm\.rs$|_linux\.rs$", "Linux only"),
    (r"macos|_mac\.rs$|/ios", "macOS or iOS only"),
    (r"android", "Android only"),
    (r"(^|/)tests?(/|\.rs$)|_tests?\.rs$|/tests/", "tests"),
    (r"^src/ui\.rs$|^src/ui/", "the old Sciter interface, not built with Flutter"),
    (r"^src/updater|^src/update_metadata|^src/update_hash|^src/manual_update", "updates (off in this build)"),
]
# Lines that never reach a person: comments, logs, panics, tests.
SKIP_LINE = re.compile(r"^\s*(//|///|\*|/\*|#\[|debugPrint|print\(|log::|(?:hbb_common::)?log::|allow_err!|bail!|anyhow!|panic!|unreachable!|assert|eprintln!|println!)")
LOG_CALL = re.compile(r"\b(log::(trace|debug|info|warn|error)!|debugPrint\(|(?<![\w.])(trace|debug|info|warn|error)!\()")

failures, allowed = [], []


def allowed_reason(rel, literal):
    for pattern, why in ALLOWED_PATHS:
        if re.search(pattern, rel):
            return why
    for path, pattern, why in ALLOWED:
        if (rel == path or (not path.endswith((".rs", ".dart")) and rel.startswith(path))) and re.search(pattern, literal):
            return why
    if re.fullmatch(r"(?i:rust)[ _-]?(?i:desk)", literal) and literal not in ("rustdesk", "RUSTDESK"):
        return None  # the name as a word ("RustDesk"): only with an entry in ALLOWED
    if not re.search(r"\s", literal) and not URL.match(literal):
        # Identifiers, options, paths, pipes, environment variables, formats. A name that ends up
        # as a file, folder, registry key, service, task, printer or process is read back from a
        # real install on the Windows runner (names-check.ps1).
        return "internal name"
    return None


# ---------------------------------------------------------------- 1. language tables
src = (ROOT / "src/emilli.rs").read_text(encoding="utf-8")
rule = re.compile(re.search(r'BASE_NAME[^=]*=\s*hbb_common::regex::Regex::new\(r"([^"]+)"\)', src).group(1))
display = re.search(r'pub const DISPLAY_NAME: &str = "([^"]+)";', src).group(1)
notice_key = re.search(r'pub const OSS_NOTICE_KEY: &str = "([^"]+)";', src).group(1)
assert notice_key == NOTICE


def shown(text, key):
    """emilli::without_base_name, in Python."""
    if key.startswith(NOTICE):
        return text

    def sub(m):
        t = m.group(0)
        if len(t) > 4 and t[:4].lower() == "http":
            return t
        return display + " Server" if m.group(1) else display

    return rule.sub(sub, text)


entry = re.compile(r'\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*\)')
tables = {}
for f in sorted((ROOT / "src/lang").glob("*.rs")):
    tables[f.name] = dict(entry.findall(f.read_text(encoding="utf-8")))
keys = set().union(*[t.keys() for t in tables.values()])
en = tables["en.rs"]
texts = 0
for name, table in tables.items():
    rel = f"src/lang/{name}"
    for key in keys:
        text = table.get(key) or en.get(key) or key
        out = shown(text, key)
        texts += 1
        if key.startswith(NOTICE):
            if NAME.search(out):
                allowed.append(f"{rel} {key}: the open-source notice")
            continue
        for part in [u for u in URL.findall(out)] + [URL.sub(" ", out)]:
            if NAME.search(part):
                why = LANG_ALLOWED.get(key) if part.lower().startswith("http") else None
                (allowed if why else failures).append(f"{rel} {key!r}: {part[:120]!r}" + (f" ({why})" if why else ""))
print(f"language tables: {len(tables)} languages, {len(keys)} keys, {texts} texts as shown")
notice_ok = all(t.get(NOTICE + "-body") for t in (tables["en.rs"], tables["ko.rs"]))
if not notice_ok:
    failures.append("the open-source notice is missing in en.rs or ko.rs")

# ---------------------------------------------------------------- 2. and 3. code strings
STRING = re.compile(r"""r?"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'""")
TRANSLATE_KEY = re.compile(r"""(translate|translateArg|msgbox|on_error)\s*\(\s*(r?["'])""")


LOG_OPEN = re.compile(r"(debugPrint|print|eprintln!|println!|log::\w+!|(?<![\w.])(trace|debug|info|warn|error)!|panic!|bail!|anyhow!|assert\w*!)\s*\(")


def scan(path, is_dart):
    rel = path.relative_to(ROOT).as_posix()
    in_tests = False
    depth = 0  # inside a log call that spans lines
    for no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not is_dart and re.match(r"^\s*#\[cfg\((all\()?test\b", line):
            in_tests = True  # tests sit at the end of a file in this code base
        if depth > 0:
            depth += line.count("(") - line.count(")")
            continue
        m = LOG_OPEN.search(line)
        if m:
            rest = line[m.end():]
            depth = max(0, 1 + rest.count("(") - rest.count(")"))
            continue
        if in_tests or SKIP_LINE.match(line) or LOG_CALL.search(line):
            continue
        code = line.split(" //")[0] if "http" not in line else line
        for m in STRING.finditer(code):
            lit = m.group(0)
            body = lit[2:-1] if lit.startswith("r") else lit[1:-1]
            if not NAME.search(body):
                continue
            before = code[: m.start()]
            if re.search(r"(translate|translateArg)\s*\(\s*$", before):
                key = re.sub(r"\{[^}]*\}", "{}", body)
                out = shown(en.get(key) or key, key)
                if NAME.search(URL.sub(" ", out)):
                    failures.append(f"{rel}:{no} translation key shows the name: {body!r} -> {out!r}")
                continue
            if not is_dart and re.search(r"msgbox\s*\(|on_error\s*\(", line) and (body in keys):
                continue  # a translation key, shown through translate (checked above)
            if not is_dart and body in keys:
                continue
            why = allowed_reason(rel, body)
            if why:
                allowed.append(f"{rel}:{no} {body[:90]!r} ({why})")
            else:
                failures.append(f"{rel}:{no} {body[:120]!r}")


for path in sorted((ROOT / "flutter/lib").rglob("*.dart")):
    scan(path, True)
for path in sorted((ROOT / "src").rglob("*.rs")):
    if path.relative_to(ROOT).as_posix().startswith("src/lang/"):
        continue
    scan(path, False)

for a in allowed:
    print("ALLOWED", a)
for f in failures:
    print("FOUND", f)
print(f"SUMMARY {len(failures)} found, {len(allowed)} allowed")
sys.exit(1 if failures else 0)
