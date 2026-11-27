//! The account/local boundary for full removal. Kept pure so the public test build proves that an
//! unavailable account service can never fall through to deleting this PC's identity.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccountAnswer {
    LeftAccount,
    WasNotInAccount,
    Unreachable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnreachableDecision {
    RemoveLocalOnly,
    Cancel,
}

/// Local identity deletion is automatic only after the account service answered. When it did not,
/// it requires the explicitly named local-only choice; closing or cancelling changes nothing.
pub fn allow_local_removal(answer: AccountAnswer, decision: Option<UnreachableDecision>) -> bool {
    match answer {
        AccountAnswer::LeftAccount | AccountAnswer::WasNotInAccount => true,
        AccountAnswer::Unreachable => decision == Some(UnreachableDecision::RemoveLocalOnly),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_account_answer_has_an_explicit_local_boundary() {
        assert!(allow_local_removal(AccountAnswer::LeftAccount, None));
        assert!(allow_local_removal(AccountAnswer::WasNotInAccount, None));
        assert!(!allow_local_removal(AccountAnswer::Unreachable, None));
        assert!(!allow_local_removal(
            AccountAnswer::Unreachable,
            Some(UnreachableDecision::Cancel)
        ));
        assert!(allow_local_removal(
            AccountAnswer::Unreachable,
            Some(UnreachableDecision::RemoveLocalOnly)
        ));
    }
}
