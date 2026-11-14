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

#[cfg(test)]
mod tests {
    use super::*;

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
