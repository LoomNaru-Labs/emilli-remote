//! Which update result belongs to the executable that is running now.

/// A result may be shown only by the version it describes. This is checked in the service state,
/// immediately before reopening the app, and once more in the app before drawing the notice.
pub fn belongs_to_running(result: &serde_json::Value, running: &str) -> bool {
    let from = result
        .get("from")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    let to = result
        .get("to")
        .and_then(|v| v.as_str())
        .unwrap_or_default();
    match result.get("result").and_then(|v| v.as_str()) {
        Some("updated") => to == running,
        Some("rolled_back") => from == running,
        Some("failed") => from == running || to == running,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn updated_notice_requires_the_running_new_version() {
        let r = json!({"result":"updated", "from":"1.5.5", "to":"1.5.6"});
        assert!(belongs_to_running(&r, "1.5.6"));
        assert!(!belongs_to_running(&r, "1.5.5"));
        assert!(!belongs_to_running(&r, "1.5.7"));
    }

    #[test]
    fn rollback_notice_requires_the_running_previous_version() {
        let r = json!({"result":"rolled_back", "from":"1.5.5", "to":"1.5.6"});
        assert!(belongs_to_running(&r, "1.5.5"));
        assert!(!belongs_to_running(&r, "1.5.6"));
        assert!(!belongs_to_running(&r, "1.5.7"));
    }

    #[test]
    fn malformed_or_another_updates_result_is_never_shown() {
        assert!(!belongs_to_running(
            &json!({"result":"updated", "to":"1.5.6"}),
            "1.5.5"
        ));
        assert!(!belongs_to_running(
            &json!({"result":"unknown", "from":"1.5.5", "to":"1.5.5"}),
            "1.5.5"
        ));
        assert!(!belongs_to_running(&json!(null), "1.5.5"));
    }
}
