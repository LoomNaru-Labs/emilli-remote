"""Read-only check that every 64-bit native library in an APK or AAB is built for 16 KB
memory pages (all PT_LOAD segments aligned to 16384 or more), as Google Play requires for
apps targeting Android 15 and higher. Exit code 1 if any library falls short.

usage: python3 check_elf_align.py <app.aab or app.apk>
"""
import struct
import sys
import zipfile

SIXTEEN_KB = 16384
ELF_MAGIC = bytes([0x7F]) + b"ELF"


def load_alignments(data: bytes):
    if data[:4] != ELF_MAGIC or data[4] != 2:  # 64-bit ELF only
        return None
    endian = "<" if data[5] == 1 else ">"
    phoff = struct.unpack_from(endian + "Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from(endian + "HH", data, 0x36)
    aligns = []
    for i in range(phnum):
        off = phoff + i * phentsize
        if struct.unpack_from(endian + "I", data, off)[0] == 1:  # PT_LOAD
            aligns.append(struct.unpack_from(endian + "Q", data, off + 0x30)[0])
    return aligns


def main() -> None:
    bad = checked = 0
    with zipfile.ZipFile(sys.argv[1]) as z:
        for name in z.namelist():
            if not name.endswith(".so") or not ("arm64-v8a" in name or "x86_64" in name):
                continue
            aligns = load_alignments(z.read(name))
            ok = bool(aligns) and min(aligns) >= SIXTEEN_KB
            checked += 1
            bad += 0 if ok else 1
            print(f"{'OK ' if ok else 'BAD'} {name} PT_LOAD align {sorted(set(aligns or []))}")
    print(f"64-bit libraries {checked}, below 16 KB {bad}")
    sys.exit(1 if bad or not checked else 0)


if __name__ == "__main__":
    main()
