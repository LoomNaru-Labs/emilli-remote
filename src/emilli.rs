//! Emilli Remote additions that are not upstream:
//!
//! - the name people see ("Emilli Remote"); the internal name in `hbb_common::config::APP_NAME`
//!   is "EmilliRemote" because Windows service and command lines need a name without spaces;
//! - the account ticket: a PC signed in to an account opens another PC of the same account
//!   without that PC's own password. The controller asks the account server for a one-time
//!   ticket bound to this connection's challenge; the PC being opened asks the account server
//!   whether the ticket is good for itself and this challenge. The server only issues a ticket
//!   when the PC belongs to the controller's account and the PC's switch allows it;
//! - the per-PC switch for that (`emilli-account-access`: direct, click, off);
//! - the PC's own proof (REMOTE-EASY-3B): binding to an account, release and the switch are
//!   signed with the key this PC registered with the ID server (see the section below);
//! - a test seam: `EMILLI_REMOTE_INSTANCE` gives a second copy on the same Windows machine its own
//!   settings, so one CI runner can play two PCs. Only letters and digits, at most 8.

use hbb_common::{
    config::{Config, LocalConfig},
    log,
};
use serde_json::json;

pub const DISPLAY_NAME: &str = "Emilli Remote";
pub const OPTION_ACCOUNT_ACCESS: &str = "emilli-account-access";
const TICKET_MAX: usize = 256;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Access {
    /// Same-account PCs connect at once; the person at this PC sees the session and can end it.
    Direct,
    /// Same-account PCs ask; someone at this PC accepts.
    Click,
    /// The account does not open this PC; only its password or a click does.
    Off,
}

impl Access {
    pub fn as_str(self) -> &'static str {
        match self {
            Access::Direct => "direct",
            Access::Click => "click",
            Access::Off => "off",
        }
    }
}

pub fn access_from(value: &str) -> Access {
    match value {
        "click" => Access::Click,
        "off" => Access::Off,
        _ => Access::Direct,
    }
}

/// This PC's switch, read where the screen is served (the service's settings when installed).
pub fn account_access() -> Access {
    access_from(&Config::get_option(OPTION_ACCOUNT_ACCESS))
}

/// Must run before anything reads the settings. See the module notes.
pub fn apply_instance_name() {
    if let Ok(v) = std::env::var("EMILLI_REMOTE_INSTANCE") {
        if !v.is_empty() && v.len() <= 8 && v.chars().all(|c| c.is_ascii_alphanumeric()) {
            *hbb_common::config::APP_NAME.write().unwrap() = format!("EmilliRemote{}", v);
        }
    }
}

fn api_server() -> String {
    crate::get_api_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    )
}

fn short(text: &str) -> String {
    text.chars().take(200).collect()
}

/// Controller side: a one-time ticket for this connection, or None (then the usual password or
/// click path follows).
pub async fn fetch_ticket(target_id: &str, challenge: &str) -> Option<Vec<u8>> {
    let token = LocalConfig::get_option("access_token");
    if token.is_empty() || challenge.is_empty() {
        return None;
    }
    let api = api_server();
    if api.is_empty() {
        return None;
    }
    let body = json!({
        "target_id": target_id,
        "challenge": challenge,
        "my_id": Config::get_id(),
    })
    .to_string();
    let header = format!("Authorization: Bearer {}", token);
    match crate::post_request_with_status(format!("{}/api/emilli/ticket", api), body, &header)
        .await
    {
        Ok((200, text)) => {
            let v: serde_json::Value = serde_json::from_str(&text).ok()?;
            let ticket = v.get("ticket")?.as_str()?;
            if ticket.is_empty() || ticket.len() > TICKET_MAX {
                return None;
            }
            log::info!("account ticket received for {}", target_id);
            Some(ticket.as_bytes().to_vec())
        }
        Ok((status, text)) => {
            log::info!("no account ticket for {}: {} {}", target_id, status, short(&text));
            None
        }
        Err(err) => {
            log::warn!("account ticket request failed: {}", err);
            None
        }
    }
}

/// PC being opened: asks the account server whether the ticket was issued for this PC and this
/// connection's challenge. Returns the account name when it was.
pub async fn check_ticket(ticket: &[u8], challenge: &str, controller_id: &str) -> Option<String> {
    let ticket = std::str::from_utf8(ticket).ok()?;
    if ticket.is_empty() || ticket.len() > TICKET_MAX || challenge.is_empty() {
        return None;
    }
    let api = api_server();
    if api.is_empty() {
        return None;
    }
    let body = json!({
        "ticket": ticket,
        "id": Config::get_id(),
        "uuid": crate::encode64(hbb_common::get_uuid()),
        "challenge": challenge,
        "controller_id": controller_id,
    })
    .to_string();
    match crate::post_request_with_status(format!("{}/api/emilli/ticket/check", api), body, "")
        .await
    {
        Ok((200, text)) => {
            let v: serde_json::Value = serde_json::from_str(&text).ok()?;
            if v.get("ok").and_then(|x| x.as_bool()) != Some(true) {
                return None;
            }
            let account = v
                .get("account")
                .and_then(|x| x.as_str())
                .unwrap_or_default()
                .to_owned();
            log::info!("account ticket accepted (account {})", account);
            Some(account)
        }
        Ok((status, text)) => {
            log::info!("account ticket refused: {} {}", status, short(&text));
            None
        }
        Err(err) => {
            log::warn!("account ticket check failed: {}", err);
            None
        }
    }
}

/// The ID server's refusals, as plain sentences (translation keys in `src/lang/*.rs`).
pub fn refusal_key(text: &str) -> Option<&'static str> {
    if text.contains("cannot access this device") {
        Some("emilli_refused_not_allowed")
    } else if text.contains("log in to Emilli Remote first") {
        Some("emilli_refused_login")
    } else if text.contains("Login server unreachable") {
        Some("emilli_refused_unreachable")
    } else {
        None
    }
}

// ---- The PC's own proof (REMOTE-EASY-3B) ----
//
// The account server binds a PC to an account, releases it, or saves its switch only for a request
// signed with the key this PC registered with the ID server for its number (the key that also
// vouches for it to controllers). The server hands out a nonce; the PC signs
// `emilli-device-proof|v1|<purpose>|<number>|<extra>|<nonce>`; the server checks the signature
// against the registered key. A number and uuid someone has seen are no longer enough.

/// The signing key pair this PC registered with the ID server, once the ID server confirmed it.
/// The app asks the process that registered (the service when installed) over local IPC.
async fn device_key() -> Option<(Vec<u8>, Vec<u8>)> {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    if !crate::is_server() {
        if let Ok(mut conn) = crate::ipc::connect(1000, "").await {
            if conn
                .send(&crate::ipc::Data::ConfirmedKey(None))
                .await
                .is_ok()
            {
                if let Ok(Some(crate::ipc::Data::ConfirmedKey(Some(pair)))) =
                    conn.next_timeout(2000).await
                {
                    return Some(pair);
                }
            }
        }
        return None;
    }
    if Config::get_key_confirmed() {
        let pair = Config::get_key_pair();
        if !pair.0.is_empty() && !pair.1.is_empty() {
            return Some(pair);
        }
    }
    None
}

pub fn proof_message(purpose: &str, id: &str, extra: &str, nonce: &str) -> String {
    format!("emilli-device-proof|v1|{}|{}|{}|{}", purpose, id, extra, nonce)
}

/// Signs `message` with an Ed25519 secret key (64 bytes) and returns the 64-byte signature.
pub fn sign_detached(sk: &[u8], message: &[u8]) -> Option<Vec<u8>> {
    use hbb_common::sodiumoxide::crypto::sign;
    if sk.len() != sign::SECRETKEYBYTES {
        return None;
    }
    let mut key = [0u8; sign::SECRETKEYBYTES];
    key.copy_from_slice(sk);
    // crypto_sign gives signature || message.
    let signed = sign::sign(message, &sign::SecretKey(key));
    Some(signed[..sign::SIGNATUREBYTES].to_vec())
}

/// A nonce from the account server for this PC and purpose, signed with this PC's own key.
pub async fn device_proof(id: &str, purpose: &str, extra: &str) -> Option<serde_json::Value> {
    let api = api_server();
    if api.is_empty() || id.is_empty() {
        return None;
    }
    let (sk, pk) = device_key().await?;
    let body = json!({ "id": id, "purpose": purpose }).to_string();
    let nonce = match crate::post_request_with_status(
        format!("{}/api/emilli/device-nonce", api),
        body,
        "",
    )
    .await
    {
        Ok((200, text)) => serde_json::from_str::<serde_json::Value>(&text)
            .ok()?
            .get("nonce")?
            .as_str()?
            .to_owned(),
        Ok((status, text)) => {
            log::info!("no device nonce: {} {}", status, short(&text));
            return None;
        }
        Err(err) => {
            log::warn!("device nonce request failed: {}", err);
            return None;
        }
    };
    let sig = sign_detached(&sk, proof_message(purpose, id, extra, &nonce).as_bytes())?;
    Some(json!({
        "nonce": nonce,
        "pk": crate::encode64(&pk),
        "sig": crate::encode64(&sig),
    }))
}

const BIND_UNREACHABLE: &str =
    "계정 서버에 닿지 못해 이 PC를 계정에 넣지 못했습니다. 잠시 뒤 Emilli Remote를 다시 열어 주세요.";
const BIND_NOT_READY: &str =
    "이 PC가 아직 서버에 등록되는 중이라 계정에 넣지 못했습니다. 잠시 뒤 Emilli Remote를 다시 열어 주세요.";
const RELEASE_UNREACHABLE: &str =
    "계정 서버에 닿지 못해 이 PC를 계정에서 빼지 못했습니다. 잠시 뒤 다시 해 주세요.";

fn server_sentence(text: &str, fallback: &str) -> String {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(|s| s.to_owned()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}

/// After sign-in: this PC joins the signed-in account, proven by its own key. Returns "" when it
/// did (or waits for the ID server's report), otherwise the sentence to show.
pub fn bind_this_pc(token: String) -> String {
    let id = crate::ui_interface::get_id();
    let uuid = crate::encode64(hbb_common::get_uuid());
    bind_this_pc_(token, id, uuid)
}

#[tokio::main(flavor = "current_thread")]
async fn bind_this_pc_(token: String, id: String, uuid: String) -> String {
    if token.is_empty() || id.is_empty() {
        return String::new();
    }
    let api = api_server();
    if api.is_empty() {
        return String::new();
    }
    // A just-installed PC may still be registering with the ID server: wait for its key a little.
    let mut proof = None;
    for _ in 0..10 {
        proof = device_proof(&id, "bind", "").await;
        if proof.is_some() {
            break;
        }
        hbb_common::sleep(2.).await;
    }
    let Some(proof) = proof else {
        log::info!("this PC is not bound yet: no device proof");
        return BIND_NOT_READY.to_owned();
    };
    let body = json!({ "id": id, "uuid": uuid, "proof": proof }).to_string();
    let header = format!("Authorization: Bearer {}", token);
    match crate::post_request_with_status(format!("{}/api/emilli/bind", api), body, &header).await
    {
        Ok((200, text)) => {
            log::info!("this PC and the account: {}", short(&text));
            String::new()
        }
        Ok((401, _)) => String::new(),
        Ok((status, text)) => {
            log::info!("this PC was not bound: {} {}", status, short(&text));
            server_sentence(&text, BIND_UNREACHABLE)
        }
        Err(err) => {
            log::warn!("bind request failed: {}", err);
            BIND_UNREACHABLE.to_owned()
        }
    }
}

/// Settings > Account: the owner takes this PC out of the account, proven by its own key.
/// Returns "" when done, otherwise the sentence to show.
pub fn release_this_pc(token: String) -> String {
    let id = crate::ui_interface::get_id();
    let uuid = crate::encode64(hbb_common::get_uuid());
    release_this_pc_(token, id, uuid)
}

#[tokio::main(flavor = "current_thread")]
async fn release_this_pc_(token: String, id: String, uuid: String) -> String {
    let api = api_server();
    if token.is_empty() || id.is_empty() || api.is_empty() {
        return RELEASE_UNREACHABLE.to_owned();
    }
    let Some(proof) = device_proof(&id, "release", "").await else {
        return RELEASE_UNREACHABLE.to_owned();
    };
    let body = json!({ "id": id, "uuid": uuid, "proof": proof }).to_string();
    let header = format!("Authorization: Bearer {}", token);
    match crate::post_request_with_status(format!("{}/api/emilli/release", api), body, &header)
        .await
    {
        Ok((200, _)) => String::new(),
        Ok((_, text)) => server_sentence(&text, RELEASE_UNREACHABLE),
        Err(err) => {
            log::warn!("release request failed: {}", err);
            RELEASE_UNREACHABLE.to_owned()
        }
    }
}

lazy_static::lazy_static! {
    static ref SAVED_ACCESS: std::sync::Mutex<Option<String>> = Default::default();
    static ref LAST_ACCESS_TRY: std::sync::Mutex<Option<std::time::Instant>> = Default::default();
}

/// Heartbeat (the process that registered with the ID server): a signed proof for the switch when
/// the account server has not saved the current value yet; at most one try a minute.
pub async fn access_proof(id: &str, access: &str) -> Option<serde_json::Value> {
    if SAVED_ACCESS.lock().unwrap().as_deref() == Some(access) {
        return None;
    }
    {
        let mut last = LAST_ACCESS_TRY.lock().unwrap();
        if last.map(|t| t.elapsed().as_secs() < 60).unwrap_or(false) {
            return None;
        }
        *last = Some(std::time::Instant::now());
    }
    device_proof(id, "access", access).await
}

/// Heartbeat answer: the value the account server saved.
pub fn access_saved(value: &str) {
    *SAVED_ACCESS.lock().unwrap() = Some(value.to_owned());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_is_a_detached_ed25519_signature_of_the_agreed_message() {
        use hbb_common::sodiumoxide::crypto::sign;
        let (pk, sk) = sign::gen_keypair();
        let msg = proof_message("access", "123456789", "click", "n0nce");
        assert_eq!(msg, "emilli-device-proof|v1|access|123456789|click|n0nce");
        let sig = sign_detached(&sk.0, msg.as_bytes()).unwrap();
        assert_eq!(sig.len(), 64);
        let mut signed = sig.clone();
        signed.extend_from_slice(msg.as_bytes());
        assert_eq!(sign::verify(&signed, &pk).unwrap(), msg.as_bytes());
        assert!(sign_detached(&sk.0[..10], b"x").is_none());
    }

    #[test]
    fn switch_values() {
        assert_eq!(access_from(""), Access::Direct);
        assert_eq!(access_from("direct"), Access::Direct);
        assert_eq!(access_from("click"), Access::Click);
        assert_eq!(access_from("off"), Access::Off);
        assert_eq!(access_from("anything"), Access::Direct);
    }

    #[test]
    fn refusals() {
        assert_eq!(
            refusal_key("This account cannot access this device (이 기기에 접근 권한이 없습니다)"),
            Some("emilli_refused_not_allowed")
        );
        assert_eq!(
            refusal_key("Please log in to Emilli Remote first (로그인이 필요합니다)"),
            Some("emilli_refused_login")
        );
        assert_eq!(refusal_key("ID does not exist"), None);
    }
}
