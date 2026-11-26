//! What the removal's answers mean (REMOTE-UX-1), apart from the windows that ask, so CI tests it on
//! its own (ci/emilli-update-tests). "Remove everything" is asked twice: the question, then a
//! warning that says what it costs (the sign-in and the link to the account are deleted, the PC
//! leaves My devices, a later install is a new PC with a new number), whose default keeps the
//! settings.

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Choice {
    Keep,
    Everything,
}

pub const ID_KEEP: i32 = 101;
pub const ID_EVERYTHING: i32 = 102;
pub const IDCANCEL: i32 = 2;
pub const IDYES: i32 = 6;
pub const IDNO: i32 = 7;
/// The warning's default button: Enter there keeps the settings.
pub const WARNING_DEFAULT: i32 = ID_KEEP;

/// The question's answer, then the warning's (asked only after "remove everything"): everything
/// goes only when both say so; "keep settings" on the warning removes the program and keeps the
/// settings; a cancel or a closed window removes nothing.
pub fn decide(first: i32, warning: impl FnOnce() -> i32) -> Option<Choice> {
    match first {
        ID_KEEP => Some(Choice::Keep),
        ID_EVERYTHING => match warning() {
            ID_KEEP => Some(Choice::Keep),
            ID_EVERYTHING => Some(Choice::Everything),
            _ => None,
        },
        _ => None,
    }
}

/// Windows' Yes / No / Cancel boxes (without the task dialog) mean the same in both: Yes keeps the
/// settings, No removes everything, Cancel removes nothing.
pub fn from_yes_no(answer: i32) -> i32 {
    match answer {
        IDYES => ID_KEEP,
        IDNO => ID_EVERYTHING,
        _ => IDCANCEL,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keep_settings_is_not_warned() {
        assert_eq!(decide(ID_KEEP, || panic!("the warning was shown for keep settings")), Some(Choice::Keep));
    }

    #[test]
    fn everything_goes_only_when_the_warning_confirms_it() {
        assert_eq!(decide(ID_EVERYTHING, || ID_EVERYTHING), Some(Choice::Everything));
        assert_eq!(decide(ID_EVERYTHING, || ID_KEEP), Some(Choice::Keep));
        assert_eq!(decide(ID_EVERYTHING, || IDCANCEL), None);
        assert_eq!(decide(ID_EVERYTHING, || 0), None);
    }

    #[test]
    fn the_warning_is_shown_once_after_remove_everything() {
        let mut shown = 0;
        let _ = decide(ID_EVERYTHING, || {
            shown += 1;
            WARNING_DEFAULT
        });
        assert_eq!(shown, 1);
    }

    #[test]
    fn enter_on_the_warning_keeps_the_settings() {
        assert_eq!(WARNING_DEFAULT, ID_KEEP);
        assert_eq!(decide(ID_EVERYTHING, || WARNING_DEFAULT), Some(Choice::Keep));
    }

    #[test]
    fn a_cancel_at_the_question_removes_nothing() {
        assert_eq!(decide(IDCANCEL, || panic!("the warning was shown after a cancel")), None);
    }

    #[test]
    fn yes_and_no_mean_the_same_in_both_boxes() {
        // No twice is the only way to everything; Yes on either keeps the settings.
        assert_eq!(decide(from_yes_no(IDNO), || from_yes_no(IDNO)), Some(Choice::Everything));
        assert_eq!(decide(from_yes_no(IDNO), || from_yes_no(IDYES)), Some(Choice::Keep));
        assert_eq!(decide(from_yes_no(IDYES), || panic!("warned")), Some(Choice::Keep));
        assert_eq!(decide(from_yes_no(IDNO), || from_yes_no(IDCANCEL)), None);
    }
}
