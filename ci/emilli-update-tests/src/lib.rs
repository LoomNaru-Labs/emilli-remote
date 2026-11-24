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
pub const TEST_KEY_B64: &str = "Q0Q5gYXRMYQTaDq9YTl87Q3PnzL4b5ZAaMK5KfWz3ZU=";

#[path = "../../../src/emilli_update/verify.rs"]
pub mod verify;
