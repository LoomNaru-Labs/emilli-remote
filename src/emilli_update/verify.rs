//! The signed version file of Emilli Remote updates (REMOTE-EASY-4). No I/O here, so CI tests this
//! file on its own (ci/emilli-update-tests) with the same crates the program uses.
//!
//! The version file (`emilli-remote-update.json`, next to the Setup on our download host):
//!
//! ```text
//! {"payload": "<JSON text, below>", "signature": "<base64 Ed25519 signature>"}
//! payload: {"app": "emilli-remote", "platform": "windows-x86_64", "version": "1.5.6",
//!           "file": "Emilli-Remote-Setup-1.5.6.exe", "size": 27195822, "sha256": "<64 hex>",
//!           "notes_ko": "...", "notes_en": "..."}
//! ```
//!
//! The signature is over `CONTEXT` followed by the payload's bytes exactly as they are in the file
//! (so nothing is re-encoded before checking), made with the release key whose public half is built
//! into the program. A file that is not signed, signed with another key, for another program or
//! platform, or not newer than the running version is refused; so is a Setup whose size or SHA-256
//! differs from the signed values.

use super::dep::{
    base64::{engine::general_purpose::STANDARD, Engine as _},
    serde_json,
    sodiumoxide::crypto::sign,
};

pub const CONTEXT: &[u8] = b"emilli-remote-update|v1\n";
pub const APP: &str = "emilli-remote";
pub const MAX_VERSION_FILE: usize = 64 * 1024;
pub const MAX_SETUP: u64 = 300 * 1024 * 1024;
const MAX_NOTES: usize = 300;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Offer {
    pub version: String,
    pub file: String,
    pub size: u64,
    pub sha256: String,
    pub notes_ko: String,
    pub notes_en: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// Not JSON of the expected shape, too large, or a field missing or malformed.
    Malformed,
    /// No signature in the file.
    Unsigned,
    /// A signature that the built-in key does not confirm.
    BadSignature,
    /// Signed, but for another program.
    WrongApp,
    /// Signed, but for another platform.
    WrongPlatform,
    /// Signed, but not newer than the running version (no downgrade, no reinstall of the same).
    NotNewer(String),
    /// The Setup's file name is not a plain "Emilli-Remote-Setup-<version>.exe".
    BadFile,
    /// The Setup's size is out of range, or the download's size differs from the signed one.
    BadSize,
    /// The SHA-256 is not 64 hex digits, or the download's SHA-256 differs from the signed one.
    BadHash,
}

impl Refusal {
    /// A short code for logs and for the app (which turns it into a sentence).
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::Malformed => "malformed",
            Refusal::Unsigned => "unsigned",
            Refusal::BadSignature => "bad-signature",
            Refusal::WrongApp => "wrong-app",
            Refusal::WrongPlatform => "wrong-platform",
            Refusal::NotNewer(_) => "not-newer",
            Refusal::BadFile => "bad-file",
            Refusal::BadSize => "bad-size",
            Refusal::BadHash => "bad-hash",
        }
    }
}

/// "1.5.6" as numbers; None unless 1 to 4 parts of digits only.
pub fn version_parts(v: &str) -> Option<Vec<u64>> {
    let parts: Vec<&str> = v.split('.').collect();
    if parts.is_empty() || parts.len() > 4 {
        return None;
    }
    let mut out = Vec::with_capacity(4);
    for p in parts {
        if p.is_empty() || p.len() > 6 || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        out.push(p.parse().ok()?);
    }
    out.resize(4, 0);
    Some(out)
}

/// True when `candidate` is a newer version than `current`.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    match (version_parts(candidate), version_parts(current)) {
        (Some(a), Some(b)) => a > b,
        _ => false,
    }
}

fn plain_setup_name(file: &str) -> bool {
    const PREFIX: &str = "Emilli-Remote-Setup-";
    const SUFFIX: &str = ".exe";
    file.len() <= 64
        && file.starts_with(PREFIX)
        && file.ends_with(SUFFIX)
        && file.len() > PREFIX.len() + SUFFIX.len()
        && version_parts(&file[PREFIX.len()..file.len() - SUFFIX.len()]).is_some()
}

fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn text(v: &serde_json::Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().map(|s| s.to_owned())
}

fn notes(v: &serde_json::Value, key: &str) -> String {
    text(v, key)
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control())
        .take(MAX_NOTES)
        .collect()
}

/// Checks a version file against the built-in public key; returns what it offers.
pub fn verify(
    file: &[u8],
    public_key: &[u8; 32],
    platform: &str,
    current_version: &str,
) -> Result<Offer, Refusal> {
    if file.len() > MAX_VERSION_FILE {
        return Err(Refusal::Malformed);
    }
    let outer: serde_json::Value = serde_json::from_slice(file).map_err(|_| Refusal::Malformed)?;
    let payload = outer
        .get("payload")
        .and_then(|p| p.as_str())
        .ok_or(Refusal::Malformed)?;
    let signature = match outer.get("signature").and_then(|s| s.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return Err(Refusal::Unsigned),
    };
    let raw = STANDARD
        .decode(signature)
        .map_err(|_| Refusal::BadSignature)?;
    let sig = sign::Signature::from_bytes(&raw).map_err(|_| Refusal::BadSignature)?;
    let mut signed = Vec::with_capacity(CONTEXT.len() + payload.len());
    signed.extend_from_slice(CONTEXT);
    signed.extend_from_slice(payload.as_bytes());
    if !sign::verify_detached(&sig, &signed, &sign::PublicKey(*public_key)) {
        return Err(Refusal::BadSignature);
    }
    let p: serde_json::Value = serde_json::from_str(payload).map_err(|_| Refusal::Malformed)?;
    if text(&p, "app").as_deref() != Some(APP) {
        return Err(Refusal::WrongApp);
    }
    if text(&p, "platform").as_deref() != Some(platform) {
        return Err(Refusal::WrongPlatform);
    }
    let version = text(&p, "version").ok_or(Refusal::Malformed)?;
    if version_parts(&version).is_none() {
        return Err(Refusal::Malformed);
    }
    if !is_newer(&version, current_version) {
        return Err(Refusal::NotNewer(version));
    }
    let file_name = text(&p, "file").ok_or(Refusal::Malformed)?;
    if !plain_setup_name(&file_name) {
        return Err(Refusal::BadFile);
    }
    let size = p.get("size").and_then(|s| s.as_u64()).ok_or(Refusal::Malformed)?;
    if size == 0 || size > MAX_SETUP {
        return Err(Refusal::BadSize);
    }
    let sha256 = text(&p, "sha256").ok_or(Refusal::Malformed)?;
    if !is_sha256_hex(&sha256) {
        return Err(Refusal::BadHash);
    }
    Ok(Offer {
        version,
        file: file_name,
        size,
        sha256,
        notes_ko: notes(&p, "notes_ko"),
        notes_en: notes(&p, "notes_en"),
    })
}

/// After the download: the Setup must be exactly the signed one.
pub fn check_download(offer: &Offer, size: u64, sha256_hex: &str) -> Result<(), Refusal> {
    if size != offer.size {
        return Err(Refusal::BadSize);
    }
    if !sha256_hex.eq_ignore_ascii_case(&offer.sha256) {
        return Err(Refusal::BadHash);
    }
    Ok(())
}

/// The built-in public key from its base64 text; None unless exactly 32 bytes.
pub fn decode_key(b64: &str) -> Option<[u8; 32]> {
    let raw = STANDARD.decode(b64.trim()).ok()?;
    raw.try_into().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLATFORM: &str = "windows-x86_64";
    const HASH: &str = "4b4d4c3a2f1e0d9c8b7a69584736251403f2e1d0c9b8a7968574635241302f1e";

    fn payload(version: &str) -> serde_json::Value {
        serde_json::json!({
            "app": APP,
            "platform": PLATFORM,
            "version": version,
            "file": format!("Emilli-Remote-Setup-{}.exe", version),
            "size": 27195822u64,
            "sha256": HASH,
            "notes_ko": "자동 업데이트",
            "notes_en": "Automatic update",
        })
    }

    fn file_with(payload: &serde_json::Value, sk: &sign::SecretKey) -> Vec<u8> {
        let text = payload.to_string();
        let mut signed = CONTEXT.to_vec();
        signed.extend_from_slice(text.as_bytes());
        let sig = sign::sign_detached(&signed, sk);
        serde_json::json!({ "payload": text, "signature": STANDARD.encode(sig.to_bytes()) })
            .to_string()
            .into_bytes()
    }

    fn keys() -> ([u8; 32], sign::SecretKey) {
        let _ = super::super::dep::sodiumoxide::init();
        let (pk, sk) = sign::gen_keypair();
        (pk.0, sk)
    }

    #[test]
    fn a_signed_newer_version_is_offered() {
        let (pk, sk) = keys();
        let offer = verify(&file_with(&payload("1.5.6"), &sk), &pk, PLATFORM, "1.5.5").unwrap();
        assert_eq!(offer.version, "1.5.6");
        assert_eq!(offer.file, "Emilli-Remote-Setup-1.5.6.exe");
        assert_eq!(offer.size, 27195822);
        assert_eq!(offer.notes_ko, "자동 업데이트");
        assert!(check_download(&offer, 27195822, &HASH.to_uppercase()).is_ok());
    }

    #[test]
    fn an_unsigned_file_is_refused() {
        let (pk, _) = keys();
        let unsigned = serde_json::json!({ "payload": payload("1.5.6").to_string() }).to_string();
        assert_eq!(verify(unsigned.as_bytes(), &pk, PLATFORM, "1.5.5"), Err(Refusal::Unsigned));
        let empty = serde_json::json!({ "payload": payload("1.5.6").to_string(), "signature": "" }).to_string();
        assert_eq!(verify(empty.as_bytes(), &pk, PLATFORM, "1.5.5"), Err(Refusal::Unsigned));
    }

    #[test]
    fn a_file_signed_with_another_key_is_refused() {
        let (pk, _) = keys();
        let (_, other) = keys();
        let file = file_with(&payload("1.5.6"), &other);
        assert_eq!(verify(&file, &pk, PLATFORM, "1.5.5"), Err(Refusal::BadSignature));
    }

    #[test]
    fn a_changed_payload_is_refused() {
        let (pk, sk) = keys();
        let file = String::from_utf8(file_with(&payload("1.5.6"), &sk)).unwrap();
        // Same signature, another Setup hash: the signature no longer matches.
        let changed = file.replace(HASH, &"0".repeat(64));
        assert_eq!(verify(changed.as_bytes(), &pk, PLATFORM, "1.5.5"), Err(Refusal::BadSignature));
        let garbage = serde_json::json!({ "payload": payload("1.5.6").to_string(), "signature": "not base64!" }).to_string();
        assert_eq!(verify(garbage.as_bytes(), &pk, PLATFORM, "1.5.5"), Err(Refusal::BadSignature));
    }

    #[test]
    fn a_version_that_is_not_newer_is_refused() {
        let (pk, sk) = keys();
        for (offered, running) in [("1.5.5", "1.5.5"), ("1.5.4", "1.5.5"), ("1.4.9", "1.5.5"), ("1.5.5", "1.5.5.1")] {
            let file = file_with(&payload(offered), &sk);
            assert_eq!(
                verify(&file, &pk, PLATFORM, running),
                Err(Refusal::NotNewer(offered.to_owned())),
                "{} over {}",
                offered,
                running
            );
        }
        assert!(verify(&file_with(&payload("1.5.10"), &sk), &pk, PLATFORM, "1.5.9").is_ok());
        assert!(verify(&file_with(&payload("1.5.5.1"), &sk), &pk, PLATFORM, "1.5.5").is_ok());
    }

    #[test]
    fn another_program_or_platform_is_refused() {
        let (pk, sk) = keys();
        let mut p = payload("1.5.6");
        p["app"] = "other".into();
        assert_eq!(verify(&file_with(&p, &sk), &pk, PLATFORM, "1.5.5"), Err(Refusal::WrongApp));
        let mut p = payload("1.5.6");
        p["platform"] = "macos-aarch64".into();
        assert_eq!(verify(&file_with(&p, &sk), &pk, PLATFORM, "1.5.5"), Err(Refusal::WrongPlatform));
    }

    #[test]
    fn a_setup_name_with_a_path_or_another_name_is_refused() {
        let (pk, sk) = keys();
        for name in ["..\\Emilli-Remote-Setup-1.5.6.exe", "x/Emilli-Remote-Setup-1.5.6.exe", "setup.exe", "Emilli-Remote-Setup-1.5.6.msi", "Emilli-Remote-Setup-.exe"] {
            let mut p = payload("1.5.6");
            p["file"] = name.into();
            assert_eq!(verify(&file_with(&p, &sk), &pk, PLATFORM, "1.5.5"), Err(Refusal::BadFile), "{}", name);
        }
    }

    #[test]
    fn a_size_or_hash_mismatch_is_refused() {
        let (pk, sk) = keys();
        let mut p = payload("1.5.6");
        p["size"] = 0u64.into();
        assert_eq!(verify(&file_with(&p, &sk), &pk, PLATFORM, "1.5.5"), Err(Refusal::BadSize));
        let mut p = payload("1.5.6");
        p["sha256"] = "abc".into();
        assert_eq!(verify(&file_with(&p, &sk), &pk, PLATFORM, "1.5.5"), Err(Refusal::BadHash));
        let offer = verify(&file_with(&payload("1.5.6"), &sk), &pk, PLATFORM, "1.5.5").unwrap();
        assert_eq!(check_download(&offer, 27195821, HASH), Err(Refusal::BadSize));
        assert_eq!(check_download(&offer, 27195822, &"f".repeat(64)), Err(Refusal::BadHash));
    }

    #[test]
    fn malformed_files_are_refused() {
        let (pk, _) = keys();
        for f in ["", "[]", "{}", "{\"payload\": 1, \"signature\": \"x\"}"] {
            assert_eq!(verify(f.as_bytes(), &pk, PLATFORM, "1.5.5"), Err(Refusal::Malformed), "{:?}", f);
        }
        assert_eq!(verify(&vec![b' '; MAX_VERSION_FILE + 1], &pk, PLATFORM, "1.5.5"), Err(Refusal::Malformed));
    }

    #[test]
    fn the_test_key_matches_its_public_seed() {
        // The test builds' key (ci/emilli-update-tests and the e2e sign with it); a release build
        // never trusts it on a non-loopback address (emilli_update.rs).
        use super::super::dep::sha2::{Digest, Sha256};
        let seed = Sha256::digest(b"emilli-remote update test key; never trusted by a release build");
        let (pk, _) = sign::keypair_from_seed(&sign::Seed::from_slice(&seed).unwrap());
        assert_eq!(STANDARD.encode(pk.0), super::super::TEST_KEY_B64);
        assert_eq!(decode_key(super::super::TEST_KEY_B64), Some(pk.0));
        assert_eq!(decode_key("AAAA"), None);
    }
}
