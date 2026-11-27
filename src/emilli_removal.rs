//! Removing Emilli Remote from Windows: one question, two choices for a person; explicit switches
//! remain non-interactive technician entry points.
//!
//! "Uninstall Emilli Remote" (Windows' installed apps, the Start menu) runs
//! `EmilliRemote.exe --uninstall`, which asks one question:
//! - keep this PC's settings (the default, as before 1.5.5): the program, its service, shortcuts,
//!   firewall rules and the updater's folder go; the settings stay, so a later install continues
//!   as the same PC (number, account, settings);
//! - remove everything (REMOTE-UX-1: only after a second window, a warning that says what it
//!   costs, whose default is keep settings; see `choice`): the same, then every settings folder of
//!   every user and of the service
//!   accounts, the folder the program unpacks into, `C:\ProgramData\EmilliRemote`, the system
//!   setting the install made, and the PC leaves its account (signed with its own key; when the
//!   account server cannot be reached, local deletion stops until the person chooses the named
//!   local-only action). A later
//!   install starts as a new PC: a new number (no longer made from the network card), signed out,
//!   default settings.
//!
//! Without the question (support, scripts), from an administrator prompt:
//!   EmilliRemote.exe --uninstall --keep-settings
//!   EmilliRemote.exe --uninstall --remove-everything
//! Not elevated, the program asks Windows for administrator rights first (one prompt), and only
//! then talks to the account server, so a cancelled prompt changes nothing.

use hbb_common::log;
use std::path::{Path, PathBuf};

mod choice;
pub use choice::Choice;
use choice::{decide, from_yes_no, IDCANCEL, ID_EVERYTHING, ID_KEEP, WARNING_DEFAULT};
mod policy;
use policy::{allow_local_removal, AccountAnswer, UnreachableDecision};

const KEEP_FLAG: &str = "--keep-settings";
const EVERYTHING_FLAG: &str = "--remove-everything";
/// Added when the question was asked here: the elevated copy then shows its sentence in a window.
const ASKED_FLAG: &str = "--asked";

fn t(key: &str) -> String {
    crate::client::translate(key.to_owned())
}

/// `--uninstall [--keep-settings | --remove-everything]`.
pub fn uninstall(args: &[String]) {
    let has = |f: &str| args.iter().any(|a| a == f);
    let asked = has(ASKED_FLAG);
    let choice = if has(EVERYTHING_FLAG) {
        Some(Choice::Everything)
    } else if has(KEEP_FLAG) {
        Some(Choice::Keep)
    } else {
        None
    };
    let (choice, asked) = match choice {
        Some(c) => (c, asked),
        None => match ask() {
            Some(c) => (c, true),
            None => {
                log::info!("removal cancelled at the question");
                return;
            }
        },
    };
    let elevated = crate::platform::is_elevated(None).unwrap_or(false);
    if !elevated {
        let flag = if choice == Choice::Everything {
            EVERYTHING_FLAG
        } else {
            KEEP_FLAG
        };
        let args = if asked {
            format!("--uninstall {} {}", flag, ASKED_FLAG)
        } else {
            format!("--uninstall {}", flag)
        };
        match std::env::current_exe() {
            Ok(exe) => {
                if !crate::platform::run_uac(&exe.to_string_lossy(), &args).unwrap_or(false) {
                    log::info!("removal: administrator rights not given");
                }
            }
            Err(e) => log::error!("removal: {}", e),
        }
        return;
    }
    remove(choice, asked);
}

fn remove(choice: Choice, show: bool) {
    log::info!("removal: {:?}", choice);
    if choice == Choice::Everything {
        let id = crate::ipc::get_id();
        let answer = match forget_this_pc(&id) {
            Some(true) => {
                log::info!("this PC left its account");
                AccountAnswer::LeftAccount
            }
            Some(false) => {
                log::info!("this PC was in no account");
                AccountAnswer::WasNotInAccount
            }
            None => {
                log::warn!("removal: the account server was not reached");
                AccountAnswer::Unreachable
            }
        };
        let decision = if answer == AccountAnswer::Unreachable {
            if show {
                ask_unreachable(&id)
            } else {
                // The technician switch stays non-interactive. It also stays safe: no account
                // answer means no local identity deletion and no uninstall fall-through.
                println!(
                    "{}",
                    t("emilli_remove_unreachable_technician").replace("{}", &spaced(&id))
                );
                None
            }
        } else {
            None
        };
        if !allow_local_removal(answer, decision) {
            log::info!("removal stopped before local deletion");
            return;
        }
        if answer == AccountAnswer::Unreachable {
            message(&t("emilli_remove_local_only_done").replace("{}", &spaced(&id)));
        }
    }
    let extra = extra_commands(choice);
    if let Err(e) = crate::platform::windows::uninstall_me_and(true, &extra) {
        log::error!("Failed to uninstall: {}", e);
    }
}

/// "123456789" as "123 456 789", as the app shows it.
fn spaced(id: &str) -> String {
    let mut out = String::new();
    for (i, c) in id.chars().enumerate() {
        if i > 0 && (id.len() - i) % 3 == 0 {
            out.push(' ');
        }
        out.push(c);
    }
    out
}

/// Some(true) left the account, Some(false) was in none, None the server did not answer (or is
/// older than rd-api 1.4.4).
fn forget_this_pc(id: &str) -> Option<bool> {
    if id.is_empty() {
        return None;
    }
    let opts = crate::ipc::get_options();
    let api = crate::get_api_server(
        opts.get("api-server").cloned().unwrap_or_default(),
        opts.get("custom-rendezvous-server")
            .cloned()
            .unwrap_or_default(),
    );
    if api.is_empty() {
        return None;
    }
    crate::emilli::forget_this_pc(api, id.to_owned())
}

fn quote(p: &Path) -> String {
    // Inside the elevated batch: quoted, and a percent sign doubled so cmd keeps it.
    format!("\"{}\"", p.to_string_lossy().replace('%', "%%"))
}

/// A folder to remove: a link (junction or symbolic link) is removed as a link, never followed.
fn rd(p: &Path) -> String {
    match std::fs::symlink_metadata(p) {
        Ok(m) if m.file_type().is_symlink() => format!("rd {}\n", quote(p)),
        Ok(_) => format!("if exist {q} rd /s /q {q}\n", q = quote(p)),
        Err(_) => String::new(),
    }
}

/// Every profile folder Windows knows: users, and the system's own (SYSTEM, LocalService,
/// NetworkService), from the registry's profile list.
fn profiles() -> Vec<PathBuf> {
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let mut out = Vec::new();
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_owned());
    if let Ok(list) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList")
    {
        for sid in list.enum_keys().flatten() {
            if let Ok(k) = list.open_subkey(&sid) {
                if let Ok(path) = k.get_value::<String, _>("ProfileImagePath") {
                    let path = path
                        .replace("%SystemRoot%", &root)
                        .replace("%systemroot%", &root)
                        .replace("%SystemDrive%", &drive);
                    if !path.contains('%') {
                        out.push(PathBuf::from(path));
                    }
                }
            }
        }
    }
    out
}

/// What the removal does beyond the program's own uninstall commands.
pub fn extra_commands(choice: Choice) -> String {
    let mut s = String::new();
    // Both choices: the updater's folder (the kept Setup, downloads, the last result) and every
    // firewall rule for the program file, whoever made it (Windows' own prompt adds some).
    if let Some(dir) = crate::emilli_update::updater_dir() {
        s += &rd(&dir);
    }
    // The update helper's start-up task, there only while it tries a new version (REMOTE-EASY-5).
    s += &format!(
        "schtasks /Delete /TN {} /F\n",
        crate::emilli_update::RESUME_TASK
    );
    let (_, _, _, exe) = crate::platform::windows::get_install_info();
    if !exe.is_empty() {
        s += &format!(
            "netsh advfirewall firewall delete rule name=all program={}\n",
            quote(Path::new(&exe))
        );
    }
    if choice == Choice::Keep {
        return s;
    }
    let app = crate::get_app_name();
    for profile in profiles() {
        for sub in ["AppData\\Roaming", "AppData\\Local", "AppData\\LocalLow"] {
            s += &rd(&profile.join(sub).join(&app));
        }
    }
    let program_data =
        std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_owned());
    s += &rd(&Path::new(&program_data).join(&app));
    // The install allows services to send Ctrl+Alt+Del (for the remote side); nothing else of ours
    // needs it once the program is gone.
    s += "reg delete HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System /v SoftwareSASGeneration /f\n";
    s
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn message(text: &str) {
    use winapi::um::winuser::{MessageBoxW, MB_ICONINFORMATION, MB_OK, MB_SETFOREGROUND};
    let title = wide(&t("emilli_remove_title"));
    let body = wide(text);
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            body.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONINFORMATION | MB_SETFOREGROUND,
        );
    }
}

// TaskDialogIndirect (comctl32 6, from the program's manifest), looked up at run time so nothing
// depends on it at load time; the layout is the SDK's (1-byte packed).
#[repr(C, packed(1))]
struct TaskDialogButton {
    id: i32,
    text: *const u16,
}

#[repr(C, packed(1))]
struct TaskDialogConfig {
    cb_size: u32,
    hwnd_parent: isize,
    h_instance: isize,
    flags: i32,
    common_buttons: i32,
    window_title: *const u16,
    main_icon: *const u16,
    main_instruction: *const u16,
    content: *const u16,
    c_buttons: u32,
    buttons: *const TaskDialogButton,
    default_button: i32,
    c_radio_buttons: u32,
    radio_buttons: *const TaskDialogButton,
    default_radio_button: i32,
    verification_text: *const u16,
    expanded_information: *const u16,
    expanded_control_text: *const u16,
    collapsed_control_text: *const u16,
    footer_icon: *const u16,
    footer: *const u16,
    callback: *const std::ffi::c_void,
    callback_data: isize,
    cx_width: u32,
}

type TaskDialogIndirect =
    unsafe extern "system" fn(*const TaskDialogConfig, *mut i32, *mut i32, *mut i32) -> i32;

#[link(name = "kernel32")]
extern "system" {
    fn LoadLibraryW(name: *const u16) -> *mut std::ffi::c_void;
    fn GetProcAddress(module: *mut std::ffi::c_void, name: *const u8) -> *mut std::ffi::c_void;
    fn GetCurrentThreadId() -> u32;
}

/// The question; None when the person cancels. "Remove everything" is asked once more (the warning).
pub fn ask() -> Option<Choice> {
    let title = wide(&t("emilli_remove_title"));
    let f = task_dialog_fn();
    let first = f.and_then(|f| {
        show(
            f,
            &title,
            false,
            "emilli_remove_question",
            "emilli_remove_content",
            &[
                (ID_KEEP, "emilli_remove_keep"),
                (ID_EVERYTHING, "emilli_remove_everything"),
                (IDCANCEL, "Cancel"),
            ],
            ID_KEEP,
        )
    });
    let first = match first {
        Some(first) => first,
        None => {
            let first = from_yes_no(message_box(
                &title,
                "emilli_remove_fallback",
                false,
                (
                    "emilli_remove_keep_short",
                    "emilli_remove_everything_short",
                    "Cancel",
                ),
            ));
            return decide(first, || {
                from_yes_no(message_box(
                    &title,
                    "emilli_remove_warning_fallback",
                    true,
                    (
                        "emilli_remove_keep_short",
                        "emilli_remove_everything_short",
                        "Cancel",
                    ),
                ))
            });
        }
    };
    decide(first, || {
        f.and_then(|f| {
            show(
                f,
                &title,
                true,
                "emilli_remove_warning_question",
                "emilli_remove_warning",
                &[
                    (ID_KEEP, "emilli_remove_warning_keep"),
                    (ID_EVERYTHING, "emilli_remove_warning_everything"),
                    (IDCANCEL, "Cancel"),
                ],
                WARNING_DEFAULT,
            )
        })
        .unwrap_or_else(|| {
            from_yes_no(message_box(
                &title,
                "emilli_remove_warning_fallback",
                true,
                (
                    "emilli_remove_keep_short",
                    "emilli_remove_everything_short",
                    "Cancel",
                ),
            ))
        })
    })
}

/// The compatibility box keeps Windows' stable button IDs, but names all three buttons with the
/// same localized actions as the task dialog. The warning has its icon.
fn message_box(title: &[u16], key: &str, warning: bool, labels: (&str, &str, &str)) -> i32 {
    use winapi::um::winuser::{
        MessageBoxW, MB_DEFBUTTON1, MB_ICONQUESTION, MB_ICONWARNING, MB_SETFOREGROUND,
        MB_YESNOCANCEL,
    };
    let body = wide(&t(key));
    let icon = if warning {
        MB_ICONWARNING
    } else {
        MB_ICONQUESTION
    };
    named_message_box(
        || unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                body.as_ptr(),
                title.as_ptr(),
                MB_YESNOCANCEL | icon | MB_DEFBUTTON1 | MB_SETFOREGROUND,
            )
        },
        [
            (choice::IDYES, t(labels.0)),
            (choice::IDNO, t(labels.1)),
            (IDCANCEL, t(labels.2)),
        ],
    )
}

thread_local! {
    static MESSAGE_BOX_LABELS: std::cell::RefCell<Vec<(i32, Vec<u16>)>> = std::cell::RefCell::new(Vec::new());
}

type Hook = *mut std::ffi::c_void;

#[link(name = "user32")]
extern "system" {
    fn SetWindowsHookExW(
        id: i32,
        callback: Option<unsafe extern "system" fn(i32, usize, isize) -> isize>,
        module: isize,
        thread: u32,
    ) -> Hook;
    fn UnhookWindowsHookEx(hook: Hook) -> i32;
    fn CallNextHookEx(hook: Hook, code: i32, wparam: usize, lparam: isize) -> isize;
    fn GetDlgItem(window: isize, id: i32) -> isize;
    fn SetWindowTextW(window: isize, text: *const u16) -> i32;
}

unsafe extern "system" fn label_message_box(code: i32, wparam: usize, lparam: isize) -> isize {
    const HCBT_ACTIVATE: i32 = 5;
    if code == HCBT_ACTIVATE {
        MESSAGE_BOX_LABELS.with(|labels| {
            for (id, text) in labels.borrow().iter() {
                let button = GetDlgItem(wparam as isize, *id);
                if button != 0 {
                    SetWindowTextW(button, text.as_ptr());
                }
            }
        });
    }
    CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam)
}

fn named_message_box<const N: usize>(
    show: impl FnOnce() -> i32,
    labels: [(i32, String); N],
) -> i32 {
    MESSAGE_BOX_LABELS.with(|slot| {
        *slot.borrow_mut() = labels
            .into_iter()
            .map(|(id, text)| (id, wide(&text)))
            .collect();
    });
    let hook = unsafe { SetWindowsHookExW(5, Some(label_message_box), 0, GetCurrentThreadId()) };
    let answer = show();
    if !hook.is_null() {
        unsafe { UnhookWindowsHookEx(hook) };
    }
    MESSAGE_BOX_LABELS.with(|slot| slot.borrow_mut().clear());
    answer
}

fn ask_unreachable(_id: &str) -> Option<UnreachableDecision> {
    let title = wide(&t("emilli_remove_title"));
    if let Some(f) = task_dialog_fn() {
        if let Some(answer) = show(
            f,
            &title,
            true,
            "emilli_remove_unreachable_question",
            "emilli_remove_unreachable_content",
            &[
                (ID_EVERYTHING, "emilli_remove_local_only"),
                (IDCANCEL, "Cancel"),
            ],
            IDCANCEL,
        ) {
            return if answer == ID_EVERYTHING {
                Some(UnreachableDecision::RemoveLocalOnly)
            } else {
                Some(UnreachableDecision::Cancel)
            };
        }
    }
    use winapi::um::winuser::{
        MessageBoxW, MB_DEFBUTTON2, MB_ICONWARNING, MB_OKCANCEL, MB_SETFOREGROUND,
    };
    let body = wide(&t("emilli_remove_unreachable_content"));
    let answer = named_message_box(
        || unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                body.as_ptr(),
                title.as_ptr(),
                MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2 | MB_SETFOREGROUND,
            )
        },
        [(1, t("emilli_remove_local_only")), (IDCANCEL, t("Cancel"))],
    );
    if answer == 1 {
        Some(UnreachableDecision::RemoveLocalOnly)
    } else {
        Some(UnreachableDecision::Cancel)
    }
}

fn task_dialog_fn() -> Option<TaskDialogIndirect> {
    unsafe {
        let module = LoadLibraryW(wide("comctl32.dll").as_ptr());
        if module.is_null() {
            None
        } else {
            let p = GetProcAddress(module, b"TaskDialogIndirect\0".as_ptr());
            if p.is_null() {
                None
            } else {
                Some(std::mem::transmute::<
                    *mut std::ffi::c_void,
                    TaskDialogIndirect,
                >(p))
            }
        }
    }
}

/// One task dialog with localized, explicitly named buttons. The pressed button's id
/// (IDCANCEL when cancelled or closed), or None when the dialog could not be shown.
fn show(
    f: TaskDialogIndirect,
    title: &[u16],
    warning: bool,
    instruction: &str,
    content: &str,
    links: &[(i32, &str)],
    default: i32,
) -> Option<i32> {
    const TDF_ALLOW_DIALOG_CANCELLATION: i32 = 0x0008;
    const TDF_USE_COMMAND_LINKS: i32 = 0x0010;
    // TD_WARNING_ICON, MAKEINTRESOURCEW(-1).
    const TD_WARNING_ICON: usize = 0xFFFF;
    let instruction = wide(&t(instruction));
    let content = wide(&t(content));
    let words: Vec<Vec<u16>> = links.iter().map(|(_, key)| wide(&t(key))).collect();
    let buttons: Vec<TaskDialogButton> = links
        .iter()
        .zip(words.iter())
        .map(|((id, _), text)| TaskDialogButton {
            id: *id,
            text: text.as_ptr(),
        })
        .collect();
    let config = TaskDialogConfig {
        cb_size: std::mem::size_of::<TaskDialogConfig>() as u32,
        hwnd_parent: 0,
        h_instance: 0,
        flags: TDF_ALLOW_DIALOG_CANCELLATION | TDF_USE_COMMAND_LINKS,
        common_buttons: 0,
        window_title: title.as_ptr(),
        main_icon: if warning {
            TD_WARNING_ICON as *const u16
        } else {
            std::ptr::null()
        },
        main_instruction: instruction.as_ptr(),
        content: content.as_ptr(),
        c_buttons: buttons.len() as u32,
        buttons: buttons.as_ptr(),
        default_button: default,
        c_radio_buttons: 0,
        radio_buttons: std::ptr::null(),
        default_radio_button: 0,
        verification_text: std::ptr::null(),
        expanded_information: std::ptr::null(),
        expanded_control_text: std::ptr::null(),
        collapsed_control_text: std::ptr::null(),
        footer_icon: std::ptr::null(),
        footer: std::ptr::null(),
        callback: std::ptr::null(),
        callback_data: 0,
        cx_width: 0,
    };
    let mut pressed = IDCANCEL;
    let hr = unsafe {
        f(
            &config,
            &mut pressed,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if hr >= 0 {
        return Some(pressed);
    }
    log::warn!(
        "the removal window could not be shown as a task dialog ({:#x})",
        hr
    );
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_are_grouped_as_the_app_shows_them() {
        assert_eq!(spaced("123456789"), "123 456 789");
        assert_eq!(spaced("1234567890"), "1 234 567 890");
        assert_eq!(spaced(""), "");
    }

    #[test]
    fn the_task_dialog_layout_is_the_sdks() {
        assert_eq!(std::mem::size_of::<TaskDialogConfig>(), 160);
        assert_eq!(std::mem::size_of::<TaskDialogButton>(), 12);
    }
}
