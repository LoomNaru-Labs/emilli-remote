"""Read-only checks of RustDesk 1.5.0 settings files, for the Emilli Remote Setup CI test.

Runs on the GitHub Windows runner only. It never changes a file and never prints a password.

  python -I check_rustdesk_config.py options <RustDesk2.toml>
      JSON with the server and password-mode options.
  python -I check_rustdesk_config.py main <RustDesk.toml> [<password file>]
      JSON with the device ID, whether a permanent password is stored, and with a password
      file whether that password (and a wrong one) matches the stored hash.

How RustDesk 1.5.0 stores these (libs/hbb_common at the 1.5.0 tag):
  - password_security.rs symmetric_crypt: NaCl secretbox, key = the machine UID
    (Windows MachineGuid) as bytes, cut or zero-padded to 32; payload = 0x01, 24-byte nonce,
    box (older payloads: box with a zero nonce).
  - config.rs Config::store: the ID is kept as enc_id = "00" + base64(payload).
  - config/permanent_password.rs: password = "01" + base64(payload), the payload opening to
    "00" + base64(sha256(password + salt)), with salt in the same file.
"""

import base64
import hashlib
import hmac
import json
import sys
import tomllib
import winreg

import nacl.exceptions
import nacl.secret

OPTION_KEYS = (
    "custom-rendezvous-server",
    "relay-server",
    "api-server",
    "key",
    "verification-method",
    "approve-mode",
)


def machine_key() -> bytes:
    flags = winreg.KEY_READ | winreg.KEY_WOW64_64KEY
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography", 0, flags) as k:
        guid = winreg.QueryValueEx(k, "MachineGuid")[0]
    return guid.encode()[:32].ljust(32, bytes(1))


def open_payload(data: bytes, key: bytes) -> bytes:
    box = nacl.secret.SecretBox(key)
    if data[:1] == bytes([1]) and len(data) >= 1 + 24 + 16:
        try:
            return box.decrypt(data[25:], data[1:25])
        except nacl.exceptions.CryptoError:
            pass
    return box.decrypt(data, bytes(24))


def decrypt_versioned(value: str, version: str, key: bytes) -> bytes:
    if len(value) <= 2 or not value.startswith(version):
        raise ValueError("not in the expected stored form")
    return open_payload(base64.b64decode(value[2:]), key)


def load(path: str) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def cmd_options(path: str) -> dict:
    options = load(path).get("options", {})
    return {k: options.get(k, "") for k in OPTION_KEYS}


def cmd_main(path: str, pw_file: str | None) -> dict:
    cfg = load(path)
    key = machine_key()
    out: dict = {"id": "", "id_error": "", "password_set": bool(cfg.get("password", ""))}
    try:
        out["id"] = decrypt_versioned(cfg.get("enc_id", ""), "00", key).decode()
    except Exception as e:  # noqa: BLE001 - reported, not raised
        out["id_error"] = type(e).__name__
    if pw_file is None:
        return out
    with open(pw_file, encoding="utf-8") as f:
        password = f.readline().rstrip("\r\n")
    salt = cfg.get("salt", "")
    out["password_match"] = False
    out["wrong_password_match"] = False
    out["password_error"] = ""
    try:
        inner = decrypt_versioned(cfg.get("password", ""), "01", key).decode()
        if not inner.startswith("00"):
            raise ValueError("inner form")
        stored = base64.b64decode(inner[2:])

        def matches(candidate: str) -> bool:
            digest = hashlib.sha256(candidate.encode() + salt.encode()).digest()
            return hmac.compare_digest(digest, stored)

        out["password_match"] = matches(password)
        out["wrong_password_match"] = matches(password + "x")
    except Exception as e:  # noqa: BLE001 - reported, not raised
        out["password_error"] = type(e).__name__
    return out


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "options":
        result = cmd_options(sys.argv[2])
    elif len(sys.argv) >= 3 and sys.argv[1] == "main":
        result = cmd_main(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        sys.exit(__doc__)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
