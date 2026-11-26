//! REMOTE-UX-1: the warning after "remove everything" says, in Korean and in English, what it costs
//! (the sign-in and the link to the account are deleted, the PC leaves My devices, a later install
//! is a new PC with a new number), and its buttons keep the order and meaning of the question's.

use emilli_update_tests::{en, ko};

fn word(t: &std::collections::HashMap<&'static str, &'static str>, key: &str) -> &'static str {
    t.get(key).copied().unwrap_or_else(|| panic!("no words for {}", key))
}

#[test]
fn the_warning_says_what_remove_everything_costs() {
    let cases: [(&std::collections::HashMap<&'static str, &'static str>, [&str; 3]); 2] = [
        (&ko::T, ["로그인과 계정 연결이 지워집니다", "'내 기기' 목록에서 이 PC가 빠집니다", "새 번호를 받은 새 PC"]),
        (&en::T, ["sign-in and its link to the account are deleted", "leaves the account's My devices list", "new PC with a new number"]),
    ];
    for (t, facts) in cases {
        for key in ["emilli_remove_warning", "emilli_remove_warning_fallback"] {
            for fact in facts {
                assert!(word(t, key).contains(fact), "{} does not say '{}'", key, fact);
            }
        }
        assert!(!word(t, "emilli_remove_warning_question").is_empty());
    }
}

#[test]
fn the_warning_offers_keep_settings_first_and_everything_second() {
    // The same two choices as the question, in the same order (keep settings first, the default).
    for (t, keep, all) in [(&*ko::T, "설정 남기기", "모두 지우기"), (&*en::T, "Keep settings", "Remove everything")] {
        assert!(word(t, "emilli_remove_keep").starts_with(keep));
        assert!(word(t, "emilli_remove_warning_keep").starts_with(keep));
        assert!(word(t, "emilli_remove_everything").starts_with(all));
        assert!(word(t, "emilli_remove_warning_everything").starts_with(all));
    }
    // Without the task dialog, Yes keeps and No removes everything in both boxes.
    let yes_keeps = |s: &str, yes: &str, no: &str| {
        let y = s.lines().find(|l| l.starts_with(yes)).unwrap_or_else(|| panic!("no '{}' line in {}", yes, s));
        let n = s.lines().find(|l| l.starts_with(no)).unwrap_or_else(|| panic!("no '{}' line in {}", no, s));
        (y.to_owned(), n.to_owned())
    };
    for key in ["emilli_remove_fallback", "emilli_remove_warning_fallback"] {
        let (y, n) = yes_keeps(word(&ko::T, key), "예:", "아니요:");
        assert!(y.contains("설정 남기기") && n.contains("모두 지우기"), "{}: {} / {}", key, y, n);
        let (y, n) = yes_keeps(word(&en::T, key), "Yes:", "No:");
        assert!(y.to_lowercase().contains("keep settings") && n.to_lowercase().contains("remove everything"), "{}: {} / {}", key, y, n);
    }
}

#[test]
fn the_first_screen_says_how_to_get_help_now() {
    // REMOTE-UX-1 (1B): the card before sign-in starts with help now; the account line keeps the
    // words of its two buttons.
    for (t, help, accept, signup, signin) in [
        (&*ko::T, "도움이 필요하면", "'수락'", "'가입'", "'로그인'"),
        (&*en::T, "Need help?", "'Accept'", "'Sign up'", "'Sign in'"),
    ] {
        assert_eq!(word(t, "emilli_start_title"), help);
        assert!(word(t, "emilli_start_body").contains(accept));
        assert!(word(t, "emilli_start_account").contains(signup) && word(t, "emilli_start_account").contains(signin));
    }
    assert_eq!(word(&ko::T, "emilli_signup"), "가입");
    assert_eq!(word(&ko::T, "emilli_signin"), "로그인");
    assert_eq!(word(&en::T, "emilli_signup"), "Sign up");
    assert_eq!(word(&en::T, "emilli_signin"), "Sign in");
    assert_eq!(word(&ko::T, "Accept"), "수락");
}
