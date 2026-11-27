//! The program's `emilli_update::verify` module, unchanged, with the crates it expects from its
//! parent module (`dep`) and the test key it compares against.

#[allow(unused_imports)]
mod dep {
    pub use ::base64;
    pub use ::serde_json;
    pub use ::sha2;
    pub use ::sodiumoxide;
}

/// Same value as `emilli_update::TEST_KEY_B64` in the program.
pub const TEST_KEY_B64: &str = "q0Q5gYXRMYQTaDq9YTl87Q3PnzL4b5ZAaMK5KfWz3ZU=";

#[path = "../../../src/emilli_update/verify.rs"]
pub mod verify;

/// REMOTE-EASY-5: when the program updates by itself (default on, registered, trial, skip).
#[path = "../../../src/emilli_update/policy.rs"]
pub mod policy;

/// REMOTE-UX-2: stale update results never reach a window for another running version.
#[path = "../../../src/emilli_update/result_notice.rs"]
pub mod result_notice;

/// REMOTE-UX-1: the helper's automatic picture fix (src/client/heal.rs), pure decisions with a virtual clock.
#[path = "../../../src/client/heal.rs"]
pub mod heal;

/// REMOTE-UX-1: what the removal's answers mean ("remove everything" only after its warning, whose
/// default keeps the settings), from src/emilli_removal/choice.rs.
#[path = "../../../src/emilli_removal/choice.rs"]
pub mod removal_choice;

/// REMOTE-UX-2: local identity deletion is gated on the account service's answer.
#[path = "../../../src/emilli_removal/policy.rs"]
pub mod removal_policy;

#[path = "../../../src/lang/en.rs"]
pub mod en;
/// The program's Korean and English words (src/lang), for the checks of the removal warning.
#[path = "../../../src/lang/ko.rs"]
pub mod ko;

#[cfg(test)]
mod ux2_contracts {
    use super::{en, ko};

    #[test]
    fn matching_update_notice_is_consumed_before_its_dialog_is_drawn() {
        let source = include_str!("../../../flutter/lib/common/widgets/emilli_update.dart");
        let show = source
            .split("Future<void> emilliShowUpdateResult()")
            .nth(1)
            .expect("update result display function")
            .split("/// Settings > About")
            .next()
            .expect("end of update result display function");
        let acknowledge = show
            .find("await emilliUpdate('ack');")
            .expect("notice acknowledgement");
        let dialog = show
            .find("await gFFI.dialogManager.show<bool>")
            .expect("notice dialog");
        assert!(
            acknowledge < dialog,
            "a window closed during the dialog must not leave its notice for an older version"
        );
    }

    #[test]
    fn store_reachable_removal_entries_never_use_the_technician_switch() {
        let source = include_str!("../../../src/platform/windows.rs");
        assert!(source.contains("shortcut_bytes(&exe, Some(\"--uninstall\")"));
        let installed_apps = source
            .lines()
            .find(|line| line.contains("UninstallString /t REG_SZ"))
            .expect("Installed apps removal entry");
        assert!(installed_apps.contains("--uninstall"));
        for line in source
            .lines()
            .filter(|line| line.contains("UninstallString") || line.contains("uninstall_shortcut"))
        {
            assert!(
                !line.contains("--remove-everything"),
                "store-reachable entry bypasses the warning: {line}"
            );
        }
    }

    #[test]
    fn every_removal_window_has_named_english_and_korean_actions() {
        for words in [&*en::T, &*ko::T] {
            for key in [
                "emilli_remove_keep_short",
                "emilli_remove_everything_short",
                "emilli_remove_local_only",
                "emilli_remove_unreachable_question",
                "emilli_remove_unreachable_content",
                "emilli_remove_local_only_done",
            ] {
                assert!(
                    !words.get(key).copied().unwrap_or_default().is_empty(),
                    "missing {key}"
                );
            }
        }
        assert_eq!(ko::T.get("Cancel"), Some(&"취소"));
        assert_eq!(
            en::T.get("emilli_remove_local_only"),
            Some(&"Remove from this PC only")
        );
        assert_eq!(
            ko::T.get("emilli_remove_local_only"),
            Some(&"이 PC에서만 제거")
        );
        assert_eq!(
            en::T.get("Request access to your device"),
            Some(&"Requesting access to this PC")
        );
        assert_eq!(
            ko::T.get("Request access to your device"),
            Some(&"이 PC에 연결을 요청하고 있습니다")
        );
        assert_eq!(
            en::T.get("display_is_plugged_out_msg"),
            Some(&"The display you were viewing was unplugged; switching to the main display.")
        );
        assert_eq!(
            ko::T.get("display_is_plugged_out_msg"),
            Some(&"보던 디스플레이가 분리되어 주 디스플레이로 전환합니다.")
        );
    }
}
