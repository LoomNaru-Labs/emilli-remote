//! When Emilli Remote updates by itself (REMOTE-EASY-5). No I/O here, so CI tests this file on its
//! own (ci/emilli-update-tests) with the same crates the program uses.
//!
//! - Automatic update is on unless someone turned it off: the setting `emilli-auto-update` reads
//!   "N" only after a person (or support, `--option emilli-auto-update N`) chose off; empty (never
//!   chosen, a new install, or an upgrade) and "Y" are on.
//! - "Registered": this PC's key is confirmed by its ID server and the server answered within the
//!   last minute (it answers every 15 s while the PC is registered).
//! - While the update helper tries a new version (its trial.json, until its "until"), no second
//!   update starts.
//! - A version the helper put back (skip.json) is not installed again by itself; a newer one is.
//! - The scheduled checks are spread: the first a random 1 to 60 minutes after the service starts,
//!   then every 24 hours plus a random 0 to 60 minutes.

use super::dep::serde_json;

/// The update helper's start-up task while it tries a new version (update.ps1 `$TaskName`); the
/// removal deletes it.
pub const RESUME_TASK: &str = "EmilliRemoteUpdate";
pub const REGISTERED_WITHIN: i64 = 60;
pub const FIRST_CHECK_MIN: u64 = 60;
pub const FIRST_CHECK_MAX: u64 = 60 * 60;
pub const DAY: u64 = 24 * 60 * 60;
pub const DAY_SPREAD: u64 = 60 * 60;

/// The setting's value: on unless it is "N".
pub fn auto_enabled(option: &str) -> bool {
    option != "N"
}

pub fn is_registered(key_confirmed: bool, last_answer: i64, now: i64) -> bool {
    key_confirmed && last_answer > 0 && now >= last_answer && now - last_answer <= REGISTERED_WITHIN
}

/// Whether the helper's trial.json (its text) is a trial still under way at `now`.
pub fn trial_active(trial_json: Option<&str>, now: i64) -> bool {
    let Some(text) = trial_json else {
        return false;
    };
    serde_json::from_str::<serde_json::Value>(text.trim_start_matches('\u{feff}'))
        .ok()
        .and_then(|v| v.get("until").and_then(|u| u.as_i64()))
        .map(|until| now < until)
        .unwrap_or(false)
}

/// The version in the helper's skip.json (its text), or "".
pub fn skipped_version(skip_json: Option<&str>) -> String {
    skip_json
        .and_then(|t| serde_json::from_str::<serde_json::Value>(t.trim_start_matches('\u{feff}')).ok())
        .and_then(|v| v.get("version").and_then(|s| s.as_str()).map(|s| s.to_owned()))
        .unwrap_or_default()
}

/// Whether an offered version may install by itself now (the remote-session wait is separate).
pub fn auto_install_allowed(option: &str, offered: &str, skipped: &str, trial: bool) -> bool {
    auto_enabled(option) && !trial && !offered.is_empty() && offered != skipped
}

/// Seconds until the first scheduled check, from a random number.
pub fn first_check_delay(random: u64) -> u64 {
    FIRST_CHECK_MIN + random % (FIRST_CHECK_MAX - FIRST_CHECK_MIN + 1)
}

/// Seconds until the next daily check, from a random number.
pub fn daily_delay(random: u64) -> u64 {
    DAY + random % (DAY_SPREAD + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn automatic_update_is_on_unless_someone_turned_it_off() {
        assert!(auto_enabled(""), "never chosen (new install, upgrade): on");
        assert!(auto_enabled("Y"));
        assert!(!auto_enabled("N"), "a recorded off stays off");
    }

    #[test]
    fn registered_means_a_confirmed_key_and_an_answer_in_the_last_minute() {
        let now = 1_800_000_000;
        assert!(is_registered(true, now - 15, now));
        assert!(is_registered(true, now - 60, now));
        assert!(!is_registered(true, now - 61, now), "the server stopped answering");
        assert!(!is_registered(false, now - 5, now), "key not confirmed");
        assert!(!is_registered(true, 0, now), "no answer since this process started");
        assert!(!is_registered(true, now + 30, now));
    }

    #[test]
    fn a_trial_under_way_blocks_a_second_update_until_its_end() {
        let now = 1_800_000_000;
        let t = format!("{{\"from\":\"1.5.5\",\"to\":\"1.5.6\",\"until\":{}}}", now + 100);
        assert!(trial_active(Some(&t), now));
        assert!(trial_active(Some(&format!("\u{feff}{}", t)), now));
        assert!(!trial_active(Some(&t), now + 100), "a trial past its end is stale");
        assert!(!trial_active(None, now));
        assert!(!trial_active(Some("not json"), now));
        assert!(!trial_active(Some("{\"from\":\"1.5.5\"}"), now));
    }

    #[test]
    fn a_rolled_back_version_is_not_installed_again_by_itself() {
        let skip = skipped_version(Some("{\"version\":\"1.5.6\",\"reason\":\"unreachable\",\"at\":1}"));
        assert_eq!(skip, "1.5.6");
        assert!(!auto_install_allowed("", "1.5.6", &skip, false), "the same version: no");
        assert!(auto_install_allowed("", "1.5.7", &skip, false), "a newer one: yes");
        assert!(!auto_install_allowed("N", "1.5.7", &skip, false), "switched off: no");
        assert!(!auto_install_allowed("", "1.5.7", &skip, true), "while a trial runs: no");
        assert!(auto_install_allowed("", "1.5.6", &skipped_version(None), false));
        assert_eq!(skipped_version(Some("garbage")), "");
    }

    #[test]
    fn the_helper_and_the_removal_name_the_same_start_up_task() {
        let helper = include_str!("update.ps1");
        assert!(helper.contains(&format!("$TaskName = '{}'", RESUME_TASK)));
    }

    #[test]
    fn checks_are_spread_over_an_hour() {
        for r in [0u64, 1, 59, 3540, 3541, u64::MAX, 123_456_789] {
            let f = first_check_delay(r);
            assert!((60..=3600).contains(&f), "first check {} s", f);
            let d = daily_delay(r);
            assert!((86_400..=90_000).contains(&d), "daily {} s", d);
        }
        assert_eq!(first_check_delay(0), 60);
        assert_eq!(first_check_delay(3540), 3600);
        assert_eq!(daily_delay(3600), 90_000);
    }
}
