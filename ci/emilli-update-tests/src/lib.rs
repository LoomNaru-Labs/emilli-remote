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

/// REMOTE-UX-1: the helper's automatic picture fix (src/client/heal.rs), pure decisions with a virtual clock.
#[path = "../../../src/client/heal.rs"]
pub mod heal;

/// REMOTE-UX-1: what the removal's answers mean ("remove everything" only after its warning, whose
/// default keeps the settings), from src/emilli_removal/choice.rs.
#[path = "../../../src/emilli_removal/choice.rs"]
pub mod removal_choice;

/// The program's Korean and English words (src/lang), for the checks of the removal warning.
#[path = "../../../src/lang/ko.rs"]
pub mod ko;
#[path = "../../../src/lang/en.rs"]
pub mod en;
