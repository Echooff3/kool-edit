//! macOS integration: Finder "Open With" / double-click delivery, ⌘Q interception so unsaved edits
//! get a prompt, and registering as the default app for audio files.
//!

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Mutex, OnceLock, mpsc};
use std::time::Duration;

use block2::RcBlock;
use eframe::egui;
use objc2::runtime::{AnyClass, AnyObject, Imp, Sel};
use objc2::{MainThreadMarker, ffi, sel};
use objc2_app_kit::{NSApplication, NSApplicationTerminateReply, NSWorkspace};
use objc2_foundation::{NSArray, NSBundle, NSError, NSString, NSURL};
use objc2_uniform_type_identifiers::UTType;

static OPEN_QUEUE: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());
static QUIT_REQUESTED: AtomicBool = AtomicBool::new(false);
static DIRTY: AtomicBool = AtomicBool::new(false);
static CTX: OnceLock<egui::Context> = OnceLock::new();

/// Audio types we register for. Must stay in sync with `macos/Info.plist`.
pub const AUDIO_UTIS: &[&str] = &[
    "public.mp3",
    "com.microsoft.waveform-audio",
    "public.aiff-audio",
    "public.aifc-audio",
    "org.xiph.flac",
    "public.mpeg-4-audio",
    "com.apple.m4a-audio",
    "public.aac-audio",
    "com.apple.coreaudio-format",
    "org.xiph.ogg-audio",
    "org.xiph.ogg-vorbis",
];

/// Lets the delegate wake the UI when Finder hands us a file while we're idle.
pub fn set_context(ctx: &egui::Context) {
    let _ = CTX.set(ctx.clone());
}

fn wake() {
    if let Some(ctx) = CTX.get() {
        ctx.request_repaint();
    }
}

pub fn take_open_requests() -> Vec<PathBuf> {
    std::mem::take(&mut *OPEN_QUEUE.lock().unwrap_or_else(|e| e.into_inner()))
}

/// Whether there are unsaved edits, so quitting (or logging out) knows whether to ask first.
pub fn set_dirty(dirty: bool) {
    DIRTY.store(dirty, SeqCst);
}

pub fn take_quit_request() -> bool {
    QUIT_REQUESTED.swap(false, SeqCst)
}

extern "C-unwind" fn open_urls(_this: &AnyObject, _cmd: Sel, _app: &AnyObject, urls: &NSArray<NSURL>) {
    let paths: Vec<PathBuf> = urls.iter().filter_map(|u| u.to_file_path()).collect();
    // One file at a time: the last one wins.
    if let Some(last) = paths.into_iter().last() {
        OPEN_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).push(last);
        wake();
    }
}

extern "C-unwind" fn should_terminate(_this: &AnyObject, _cmd: Sel, _app: &AnyObject) -> NSApplicationTerminateReply {
    if CTX.get().is_none() || !DIRTY.load(SeqCst) {
        return NSApplicationTerminateReply::TerminateNow;
    }
    // Unsaved edits: let the UI ask, then close the window itself.
    QUIT_REQUESTED.store(true, SeqCst);
    wake();
    NSApplicationTerminateReply::TerminateCancel
}

/// Teach winit's application delegate two extra tricks. winit owns the delegate (and panics if
/// it's replaced), so we add methods to its class instead. Call after the event loop is built and
/// before it runs, so the launch-time "open these files" event reaches us.
pub fn install_delegate_hooks() -> bool {
    let Some(mtm) = MainThreadMarker::new() else { return false };
    let app = NSApplication::sharedApplication(mtm);
    let Some(delegate) = app.delegate() else { return false };
    let obj: &AnyObject = delegate.as_ref();
    let cls = obj.class() as *const AnyClass as *mut AnyClass;
    type OpenUrls = extern "C-unwind" fn(&AnyObject, Sel, &AnyObject, &NSArray<NSURL>);
    type ShouldTerminate = extern "C-unwind" fn(&AnyObject, Sel, &AnyObject) -> NSApplicationTerminateReply;
    // SAFETY: the implementations match the selectors' signatures and type encodings.
    let added = unsafe {
        let open = std::mem::transmute::<OpenUrls, Imp>(open_urls);
        let quit = std::mem::transmute::<ShouldTerminate, Imp>(should_terminate);
        let a = ffi::class_addMethod(cls, sel!(application:openURLs:), open, c"v@:@@".as_ptr());
        let b = ffi::class_addMethod(cls, sel!(applicationShouldTerminate:), quit, c"Q@:@".as_ptr());
        a.as_bool() && b.as_bool()
    };
    // Re-set the delegate so AppKit re-checks what it responds to.
    app.setDelegate(None);
    app.setDelegate(Some(&delegate));
    added
}

/// Ask Launch Services to make this app bundle the default for common audio types.
/// Blocks (briefly) for the results.
pub fn make_default_player() -> Result<String, String> {
    let bundle = NSBundle::mainBundle();
    let bundle_path = bundle.bundlePath().to_string();
    if !bundle_path.ends_with(".app") || bundle.bundleIdentifier().is_none() {
        return Err("Kool Edit isn't running from its app bundle. Run scripts/install.sh, then use \
                    File ▸ Make Default Audio Player from the installed app."
            .to_owned());
    }
    let app_url = bundle.bundleURL();
    let workspace = NSWorkspace::sharedWorkspace();
    let (tx, rx) = mpsc::channel::<Option<String>>();
    let mut pending = 0;
    let mut skipped = Vec::new();
    for uti in AUDIO_UTIS {
        let Some(ty) = UTType::typeWithIdentifier(&NSString::from_str(uti)) else {
            skipped.push(*uti);
            continue;
        };
        let tx = tx.clone();
        let uti = uti.to_string();
        let done = RcBlock::new(move |err: *mut NSError| {
            let msg = unsafe { err.as_ref() }.map(|e| format!("{uti}: {}", e.localizedDescription()));
            let _ = tx.send(msg);
        });
        workspace.setDefaultApplicationAtURL_toOpenContentType_completionHandler(&app_url, &ty, Some(&done));
        pending += 1;
    }
    let mut errors = Vec::new();
    let mut ok = 0;
    for _ in 0..pending {
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(None) => ok += 1,
            Ok(Some(e)) => errors.push(e),
            Err(_) => {
                errors.push("timed out waiting for Launch Services".to_owned());
                break;
            }
        }
    }
    if ok == 0 {
        return Err(format!("Couldn't set Kool Edit as the default player: {}", errors.join("; ")));
    }
    let mut msg = format!("Kool Edit is now the default player for {ok} audio types");
    if !errors.is_empty() {
        msg.push_str(&format!(" ({} failed: {})", errors.len(), errors.join("; ")));
    }
    if !skipped.is_empty() {
        eprintln!("kool-edit: types unknown to this system: {}", skipped.join(", "));
    }
    Ok(msg)
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFRunLoopDefaultMode: *const std::ffi::c_void;
    fn CFRunLoopRunInMode(mode: *const std::ffi::c_void, seconds: f64, return_after_source_handled: u8) -> i32;
}

/// `--make-default` from the command line: register, pumping the main run loop in case
/// Launch Services replies on the main queue.
pub fn make_default_player_cli() -> Result<String, String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(make_default_player());
    });
    loop {
        match rx.try_recv() {
            Ok(result) => return result,
            Err(mpsc::TryRecvError::Disconnected) => return Err("registration thread died".to_owned()),
            Err(mpsc::TryRecvError::Empty) => unsafe {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 0);
            },
        }
    }
}
