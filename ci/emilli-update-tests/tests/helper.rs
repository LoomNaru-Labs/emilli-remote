//! REMOTE-EASY-5: the update helper's decisions (helper-tests.ps1: each case of the roll-back table,
//! with a virtual clock and nothing installed), run with this crate's tests so the CI step that runs
//! `cargo test` here runs them too. Needs PowerShell (pwsh; on Windows also Windows PowerShell); with
//! none, or with output that cannot be read, the test fails.

use std::process::Command;

#[test]
fn the_update_helper_decides_each_case_of_the_roll_back_table() {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/helper-tests.ps1");
    let shells: &[&str] = if cfg!(windows) { &["pwsh", "powershell"] } else { &["pwsh"] };
    for shell in shells {
        let out = match Command::new(shell)
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script])
            .output()
        {
            Ok(out) => out,
            Err(err) => {
                eprintln!("{}: {}", shell, err);
                continue;
            }
        };
        let text = String::from_utf8_lossy(&out.stdout);
        println!("{}", text);
        eprintln!("{}", String::from_utf8_lossy(&out.stderr));
        let passed = text.lines().filter(|l| l.starts_with("PASS ")).count();
        assert!(
            out.status.success() && text.contains("helper tests: 0 failed"),
            "helper tests failed ({:?})",
            out.status
        );
        assert!(passed >= 17, "only {} cases read as passed", passed);
        return;
    }
    panic!("no PowerShell to run helper-tests.ps1");
}
