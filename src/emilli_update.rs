//! Emilli Remote updates from our own download host (REMOTE-EASY-4). Windows, installed copies only.
//!
//! - Where: the build configuration gives the folder (`EMILLI_UPDATE_URL`, https, or http on
//!   127.0.0.1 for the CI test builds) and the release key's public half (`EMILLI_UPDATE_KEY`).
//!   A build without both has no updater. Nothing here talks to the base software's addresses
//!   (its own update code stays switched off: `common::do_check_software_update`).
//! - Check: the service-side process (`--server`, SYSTEM) fetches `emilli-remote-update.json`
//!   from that folder 30 s after it starts and once a day, and when someone presses "Check for
//!   updates" in Settings > About. The request carries nothing but this version and platform (in
//!   its User-Agent). The file must be signed with the release key (verify.rs).
//! - One press: the same process downloads the Setup named in the file into a folder only
//!   administrators can write (`<Program Files>\EmilliRemoteUpdate\work`), checks its size and
//!   SHA-256 against the signed values, and starts a small PowerShell helper (update.ps1) as
//!   SYSTEM outside the program, which survives the program being replaced. The helper runs the
//!   Setup silently (the PC keeps its number, account and settings, as with a manual install),
//!   waits until the new service answers and reports the new version, and otherwise puts the
//!   previous version back with the Setup kept from the last install
//!   (`<Program Files>\EmilliRemoteUpdate\kept`, written by Emilli Remote Setup), then writes
//!   `last-result.json`. The new process reopens the window when the update was started from it,
//!   and the window says what happened, once.
//! - Automatic (REMOTE-EASY-5: on unless someone turned it off, policy.rs): a found update
//!   installs by itself when no remote session is active; with a session, it waits and tries again
//!   every 30 minutes. No quiet hours. The scheduled checks are spread (the first a random 1 to 60
//!   minutes after the service starts, then every 24 hours plus a random 0 to 60 minutes).
//! - An update that leaves the PC unreachable undoes itself (REMOTE-EASY-5): the helper also waits
//!   until the new version is registered with its ID server and stays so for 10 minutes ("registered"
//!   in this process's state, from the ID server's answers), and puts the previous version back
//!   otherwise; time when the helper itself cannot reach the ID server does not count (no
//!   connection at all is not a failed update). A version put back is not installed again by
//!   itself, and no second update starts while one is being tried.

pub mod policy;
pub mod result_notice;
pub mod verify;

#[allow(unused_imports)]
mod dep {
    pub use hbb_common::{base64, sha2, sodiumoxide};
    pub use serde_json;
}

use hbb_common::{config::Config, log, tokio};
use serde_json::json;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicI64, Ordering},
        Mutex, Once,
    },
    time::Duration,
};

/// The test builds' key. Its private half comes from a public seed (verify.rs, test
/// `the_test_key_matches_its_public_seed`), so a build that trusts it updates only from 127.0.0.1.
pub const TEST_KEY_B64: &str = "q0Q5gYXRMYQTaDq9YTl87Q3PnzL4b5ZAaMK5KfWz3ZU=";
pub const VERSION_FILE: &str = "emilli-remote-update.json";
pub const OPTION_AUTO: &str = "emilli-auto-update";
pub const PLATFORM: &str = "windows-x86_64";
/// The folder next to the program folder: kept Setup, downloads, the helper, the last result.
pub const UPDATER_DIR: &str = "EmilliRemoteUpdate";
pub const KEPT_SETUP: &str = "Emilli-Remote-Setup.exe";
const RESULT_FILE: &str = "last-result.json";
/// Written by the helper while it tries a new version (work folder), and when it put one back.
const TRIAL_FILE: &str = "trial.json";
const SKIP_FILE: &str = "skip.json";
pub use policy::RESUME_TASK;
const HELPER: &str = include_str!("emilli_update/update.ps1");
const RETRY: Duration = Duration::from_secs(30 * 60);

/// When the ID server last answered this process's registration (Unix seconds; 0: not yet).
static LAST_REGISTERED: AtomicI64 = AtomicI64::new(0);

/// Called by the rendezvous mediator on every answer of the ID server to this PC's registration.
pub fn note_registered() {
    LAST_REGISTERED.store(now(), Ordering::Relaxed);
}

/// Registered with the ID server the way a working install is (policy.rs).
pub fn registered() -> bool {
    policy::is_registered(
        Config::get_key_confirmed(),
        LAST_REGISTERED.load(Ordering::Relaxed),
        now(),
    )
}

/// The ID server this PC registers with, as host:port (the helper checks it can reach it).
fn id_server() -> String {
    crate::check_port(
        Config::get_rendezvous_server(),
        hbb_common::config::RENDEZVOUS_PORT,
    )
}

/// The update folder and key of this build, or None (no updater in this build).
pub fn config() -> Option<(&'static str, [u8; 32])> {
    config_of(
        option_env!("EMILLI_UPDATE_URL")?,
        option_env!("EMILLI_UPDATE_KEY")?,
    )
}

fn config_of(url: &'static str, key: &str) -> Option<(&'static str, [u8; 32])> {
    let key = verify::decode_key(key)?;
    let loopback = url.starts_with("http://127.0.0.1:") || url.starts_with("http://127.0.0.1/");
    if !(url.starts_with("https://") || loopback) || !url.ends_with('/') || url.contains('?') {
        return None;
    }
    if Some(key) == verify::decode_key(TEST_KEY_B64) && !loopback {
        return None;
    }
    Some((url, key))
}

#[derive(Default)]
struct State {
    /// "checking", "downloading" or "installing" while that runs.
    busy: &'static str,
    /// After the last check: "up-to-date", "available" or "error".
    status: &'static str,
    offer: Option<verify::Offer>,
    /// Why the last check or install did not go on (a code the app turns into a sentence).
    error: String,
    checked_at: i64,
    /// When the current job started (an install that never ends is given up after 20 minutes).
    busy_since: i64,
    /// An automatic update found while a remote session was active waits for it to end.
    auto_waiting: bool,
}

lazy_static::lazy_static! {
    static ref STATE: Mutex<State> = Default::default();
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

fn auto_on() -> bool {
    policy::auto_enabled(&Config::get_option(OPTION_AUTO))
}

fn trial_active() -> bool {
    let text =
        updater_dir().and_then(|d| std::fs::read_to_string(d.join("work").join(TRIAL_FILE)).ok());
    policy::trial_active(text.as_deref(), now())
}

fn skipped() -> String {
    let text = updater_dir().and_then(|d| std::fs::read_to_string(d.join(SKIP_FILE)).ok());
    policy::skipped_version(text.as_deref())
}

fn program_dir() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        let (_, path, _, _) = crate::platform::windows::get_install_info();
        if !path.is_empty() {
            return Some(PathBuf::from(path));
        }
    }
    None
}

/// `<Program Files>\EmilliRemoteUpdate`, beside the program folder (only administrators write there).
pub fn updater_dir() -> Option<PathBuf> {
    Some(program_dir()?.parent()?.join(UPDATER_DIR))
}

fn result_path() -> Option<PathBuf> {
    Some(updater_dir()?.join(RESULT_FILE))
}

fn read_result() -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(result_path()?).ok()?;
    serde_json::from_str::<serde_json::Value>(text.trim_start_matches('\u{feff}'))
        .ok()
        .filter(|v| v.is_object())
}

fn write_result(v: &serde_json::Value) {
    if let Some(p) = result_path() {
        hbb_common::allow_err!(std::fs::write(p, v.to_string()));
    }
}

/// Serves the app's requests ("state", "check", "install", "ack"; "auto" runs the scheduled check
/// now, for support and the CI test) in the process that registered with the ID server; never
/// blocks (the work runs on its own thread). Returns the state as JSON.
pub fn handle_ipc(request: &str) -> String {
    let op = serde_json::from_str::<serde_json::Value>(request)
        .ok()
        .and_then(|v| v.get("op").and_then(|o| o.as_str()).map(|s| s.to_owned()))
        .unwrap_or_default();
    if ready() {
        match op.as_str() {
            "check" => start(Job::Check),
            "install" => start(Job::Install { reopen: true }),
            "auto" => {
                std::thread::spawn(scheduled_check);
            }
            "ack" => {
                if let Some(mut r) = read_result() {
                    if result_notice::belongs_to_running(&r, crate::VERSION) {
                        r["shown"] = json!(1);
                        write_result(&r);
                    }
                }
            }
            _ => {}
        }
    }
    state_json()
}

fn ready() -> bool {
    config().is_some() && crate::platform::is_installed()
}

pub fn state_json() -> String {
    let mut s = STATE.lock().unwrap();
    if s.busy == "installing" && now() - s.busy_since > 20 * 60 {
        // The helper should have replaced this process long ago.
        s.busy = "";
        s.error = "stalled".to_owned();
    }
    let offer = s.offer.clone();
    let trial = trial_active();
    let result = read_result().filter(|r| result_notice::belongs_to_running(r, crate::VERSION));
    json!({
        "configured": config().is_some(),
        "installed": crate::platform::is_installed(),
        "current": crate::VERSION,
        // While the helper tries the new version, the app says so and offers no button.
        "busy": if s.busy.is_empty() && trial { "confirming" } else { s.busy },
        "status": s.status,
        "version": offer.as_ref().map(|o| o.version.clone()).unwrap_or_default(),
        "notes_ko": offer.as_ref().map(|o| o.notes_ko.clone()).unwrap_or_default(),
        "notes_en": offer.as_ref().map(|o| o.notes_en.clone()).unwrap_or_default(),
        "error": s.error,
        "checked_at": s.checked_at,
        "auto": auto_on(),
        "auto_waiting": s.auto_waiting,
        "result": result,
        "registered": registered(),
        "trial": trial,
        "skipped": skipped(),
    })
    .to_string()
}

#[derive(Clone, Copy)]
enum Job {
    Check,
    Install { reopen: bool },
}

fn start(job: Job) {
    {
        let mut s = STATE.lock().unwrap();
        if !s.busy.is_empty() {
            return;
        }
        s.busy = match job {
            Job::Check => "checking",
            Job::Install { .. } => "downloading",
        };
        s.busy_since = now();
        s.error.clear();
    }
    std::thread::spawn(move || {
        let reopen = match job {
            Job::Check => {
                check_now();
                STATE.lock().unwrap().busy = "";
                return;
            }
            Job::Install { reopen } => reopen,
        };
        // The version file as it is now: an offer kept from an earlier check may name a Setup that
        // a newer release has replaced (two releases one after the other).
        check_now();
        let offer = STATE.lock().unwrap().offer.clone();
        let result = match offer {
            Some(o) => install(&o, reopen),
            None => Err(STATE.lock().unwrap().error.clone()),
        };
        let mut s = STATE.lock().unwrap();
        match result {
            Ok(()) => s.busy = "installing",
            Err(e) => {
                log::warn!("update not installed: {}", e);
                s.busy = "";
                if !e.is_empty() {
                    s.error = e;
                }
            }
        }
    });
}

/// Fetches and checks the version file; keeps what it offers. Blocking.
fn check_now() {
    let result = check();
    let mut s = STATE.lock().unwrap();
    s.checked_at = now();
    match result {
        Ok(Some(offer)) => {
            log::info!("update available: {} -> {}", crate::VERSION, offer.version);
            s.offer = Some(offer);
            s.status = "available";
            s.error.clear();
        }
        Ok(None) => {
            s.offer = None;
            s.status = "up-to-date";
            s.error.clear();
        }
        Err(code) => {
            log::warn!("update check: {}", code);
            s.status = "error";
            s.error = code;
        }
    }
}

fn check() -> Result<Option<verify::Offer>, String> {
    let (base, key) = config().ok_or_else(|| "not-configured".to_owned())?;
    let url = format!("{}{}", base, VERSION_FILE);
    let bytes = fetch(&url, verify::MAX_VERSION_FILE as u64).map_err(|e| {
        log::warn!("update check {}: {}", url, e);
        "unreachable".to_owned()
    })?;
    match verify::verify(&bytes, &key, PLATFORM, crate::VERSION) {
        Ok(offer) => Ok(Some(offer)),
        Err(verify::Refusal::NotNewer(v)) => {
            log::info!(
                "update check: the offered {} is not newer than {}",
                v,
                crate::VERSION
            );
            Ok(None)
        }
        Err(r) => Err(r.code().to_owned()),
    }
}

fn client(url: &str) -> hbb_common::ResultType<reqwest::blocking::Client> {
    if url.starts_with("https://") {
        crate::hbbs_http::create_http_client_with_url_strict(url)
    } else {
        Ok(crate::hbbs_http::create_http_client_with_url(url))
    }
}

fn user_agent() -> String {
    format!("EmilliRemote/{} ({})", crate::VERSION, PLATFORM)
}

/// GET into memory, at most `max` bytes.
fn fetch(url: &str, max: u64) -> hbb_common::ResultType<Vec<u8>> {
    use std::io::Read;
    let resp = client(url)?
        .get(url)
        .header("User-Agent", user_agent())
        .timeout(Duration::from_secs(30))
        .send()?;
    if !resp.status().is_success() {
        hbb_common::bail!("HTTP {}", resp.status());
    }
    let mut out = Vec::new();
    resp.take(max + 1).read_to_end(&mut out)?;
    if out.len() as u64 > max {
        hbb_common::bail!("larger than {} bytes", max);
    }
    Ok(out)
}

/// GET into a file, at most `max` bytes; returns the size and the SHA-256 (hex).
fn download(url: &str, dest: &std::path::Path, max: u64) -> hbb_common::ResultType<(u64, String)> {
    use hbb_common::sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    let mut resp = client(url)?
        .get(url)
        .header("User-Agent", user_agent())
        .timeout(Duration::from_secs(30 * 60))
        .send()?;
    if !resp.status().is_success() {
        hbb_common::bail!("HTTP {}", resp.status());
    }
    let part = dest.with_extension("part");
    let mut file = std::fs::File::create(&part)?;
    let mut hasher = Sha256::new();
    let mut total = 0u64;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = resp.read(&mut buf)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > max {
            drop(file);
            std::fs::remove_file(&part).ok();
            hbb_common::bail!("larger than {} bytes", max);
        }
        hasher.update(&buf[..n]);
        file.write_all(&buf[..n])?;
    }
    file.sync_all()?;
    drop(file);
    std::fs::rename(&part, dest)?;
    let hex: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    Ok((total, hex))
}

/// Downloads and checks the Setup, then starts the helper. Err carries a code for the app.
#[cfg(windows)]
fn install(offer: &verify::Offer, reopen: bool) -> Result<(), String> {
    let (base, _) = config().ok_or_else(|| "not-configured".to_owned())?;
    let program = program_dir().ok_or_else(|| "not-installed".to_owned())?;
    let dir = updater_dir().ok_or_else(|| "not-installed".to_owned())?;
    if trial_active() {
        // The helper is still trying the last update; its work folder stays as it is.
        return Err("busy".to_owned());
    }
    let kept = dir.join("kept").join(KEPT_SETUP);
    if !kept.is_file() {
        // Without the Setup of the running version there is nothing to go back to.
        return Err("no-rollback".to_owned());
    }
    let work = dir.join("work");
    std::fs::remove_dir_all(&work).ok();
    std::fs::create_dir_all(&work).map_err(|e| {
        log::error!("update folder {}: {}", work.display(), e);
        "disk".to_owned()
    })?;
    let setup = work.join(&offer.file);
    let url = format!("{}{}", base, offer.file);
    let (size, sha) = download(&url, &setup, verify::MAX_SETUP).map_err(|e| {
        log::warn!("update download {}: {}", url, e);
        "unreachable".to_owned()
    })?;
    if let Err(r) = verify::check_download(offer, size, &sha) {
        log::error!(
            "downloaded Setup refused: {} (size {}, SHA-256 {})",
            r.code(),
            size,
            sha
        );
        std::fs::remove_file(&setup).ok();
        return Err(r.code().to_owned());
    }
    log::info!(
        "Setup {} downloaded and checked (SHA-256 {})",
        offer.file,
        sha
    );
    {
        let mut s = STATE.lock().unwrap();
        s.busy = "installing";
        s.busy_since = now();
    }
    let script = work.join("update.ps1");
    std::fs::write(&script, HELPER).map_err(|_| "disk".to_owned())?;
    let args: Vec<String> = vec![
        "-Setup".into(),
        setup.to_string_lossy().into(),
        "-Version".into(),
        offer.version.clone(),
        "-From".into(),
        crate::VERSION.into(),
        "-Kept".into(),
        kept.to_string_lossy().into(),
        "-Program".into(),
        program.to_string_lossy().into(),
        "-Result".into(),
        dir.join(RESULT_FILE).to_string_lossy().into(),
        "-Reopen".into(),
        (if reopen { "1" } else { "0" }).into(),
        "-Server".into(),
        id_server(),
        "-Registered".into(),
        (if registered() { "1" } else { "0" }).into(),
    ];
    launch_helper(&script, &args)
}

#[cfg(not(windows))]
fn install(_offer: &verify::Offer, _reopen: bool) -> Result<(), String> {
    Err("not-installed".to_owned())
}

/// PowerShell as SYSTEM in this process's session, outside its job, with no window.
#[cfg(windows)]
fn launch_helper(script: &std::path::Path, args: &[String]) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
    let ps = PathBuf::from(root).join("System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    let run = |flags: u32| {
        std::process::Command::new(&ps)
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
            ])
            .arg(script)
            .args(args)
            .creation_flags(flags)
            .spawn()
    };
    let base = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP;
    match run(base | CREATE_BREAKAWAY_FROM_JOB).or_else(|_| run(base)) {
        Ok(child) => {
            log::info!("update helper started (pid {})", child.id());
            Ok(())
        }
        Err(e) => {
            log::error!("update helper did not start: {}", e);
            Err("helper".to_owned())
        }
    }
}

static STARTED: Once = Once::new();

/// In the installed program's service-side process: the first check 30 s after start, then daily;
/// an automatic update when switched on; and reopening the window after an update started from it.
pub fn start_service_side() {
    if !ready() || !crate::is_server() {
        return;
    }
    STARTED.call_once(|| {
        std::thread::spawn(reopen_after_update);
        std::thread::spawn(|| {
            use hbb_common::rand::Rng;
            let first = policy::first_check_delay(hbb_common::rand::thread_rng().gen());
            log::info!("first update check in {} s", first);
            std::thread::sleep(Duration::from_secs(first));
            loop {
                let wait = scheduled_check();
                std::thread::sleep(wait);
            }
        });
    });
}

/// One scheduled check (and automatic install); returns how long to wait for the next.
fn scheduled_check() -> Duration {
    if !STATE.lock().unwrap().busy.is_empty() {
        return RETRY;
    }
    STATE.lock().unwrap().busy = "checking";
    check_now();
    STATE.lock().unwrap().busy = "";
    let day = || {
        use hbb_common::rand::Rng;
        Duration::from_secs(policy::daily_delay(hbb_common::rand::thread_rng().gen()))
    };
    let offered = STATE
        .lock()
        .unwrap()
        .offer
        .as_ref()
        .map(|o| o.version.clone())
        .unwrap_or_default();
    let trial = trial_active();
    let skip = skipped();
    if !policy::auto_install_allowed(&Config::get_option(OPTION_AUTO), &offered, &skip, trial) {
        STATE.lock().unwrap().auto_waiting = false;
        if trial {
            log::info!("automatic update waits: the last update is still being tried");
            return RETRY;
        }
        if !offered.is_empty() && offered == skip {
            log::info!(
                "automatic update: {} was put back before, not installed again by itself",
                offered
            );
        }
        return day();
    }
    if !crate::updater::has_no_active_conns() {
        log::info!("automatic update waits: a remote session is active");
        STATE.lock().unwrap().auto_waiting = true;
        return RETRY;
    }
    STATE.lock().unwrap().auto_waiting = false;
    log::info!("automatic update starts");
    start(Job::Install { reopen: false });
    RETRY
}

/// After an update started from the window: the helper writes the result when the new version
/// answers (or the old one is back); open the window then, once, so it can say what happened.
fn reopen_after_update() {
    for _ in 0..240 {
        if let Some(mut r) = read_result() {
            if !result_notice::belongs_to_running(&r, crate::VERSION) {
                log::info!(
                    "stale update result does not belong to running version; window stays closed"
                );
                return;
            }
            let fresh = r["at"]
                .as_i64()
                .map(|at| now() - at < 30 * 60)
                .unwrap_or(false);
            let wanted = r["reopen"].as_i64() == Some(1) && r["reopened"].as_i64() != Some(1);
            if !(fresh && wanted) {
                return;
            }
            r["reopened"] = json!(1);
            write_result(&r);
            log::info!("update result {}: opening the window", r["result"]);
            // Shown: run_as_user starts the process with SW_HIDE in its start-up information,
            // which Windows applies to the window's first ShowWindow, so the window stayed hidden
            // until someone opened the program again (laptop end to end, 2026-11-25).
            #[cfg(windows)]
            if let Ok(exe) = std::env::current_exe() {
                hbb_common::allow_err!(crate::platform::run_exe_in_cur_session(
                    &exe.to_string_lossy(),
                    vec![],
                    true
                ));
            }
            return;
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}

/// The app side: asks the service-side process over local IPC. Returns its state as JSON, or
/// {"service": false} when it does not answer (not installed, or the service is not running).
#[tokio::main(flavor = "current_thread")]
pub async fn ask_service(request: String) -> String {
    if let Ok(mut conn) = crate::ipc::connect(1000, "").await {
        if conn
            .send(&crate::ipc::Data::EmilliUpdate(request))
            .await
            .is_ok()
        {
            if let Ok(Some(crate::ipc::Data::EmilliUpdate(answer))) = conn.next_timeout(3000).await
            {
                return answer;
            }
        }
    }
    json!({
        "service": false,
        "configured": config().is_some(),
        "installed": crate::platform::is_installed(),
        "current": crate::VERSION,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_or_this_machine_and_never_the_test_key_elsewhere() {
        let real = "K0yJr4tGvKgTlDsbrq0f0qQFk9N2hTBgzN9u5cQZ1xQ=";
        assert!(config_of("https://rd.example.net/update/", real).is_some());
        assert!(config_of("http://127.0.0.1:21180/update/", TEST_KEY_B64).is_some());
        assert!(config_of("https://rd.example.net/update/", TEST_KEY_B64).is_none());
        assert!(config_of("http://rd.example.net/update/", real).is_none());
        assert!(config_of("https://rd.example.net/update", real).is_none());
        assert!(config_of("https://rd.example.net/update/", "AAAA").is_none());
    }
}
