//! The editor window: state, actions, and layout.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, mpsc};
use std::time::Instant;

use eframe::egui::{
    self, Align2, Color32, CornerRadius, CursorIcon, Event, FontId, Key, Modifiers, Panel, Rect, Sense, Stroke, Ui,
    ViewportCommand, pos2, vec2,
};

use crate::audio::{Effect, Samples};
use crate::decode::{self, Loaded};
use crate::doc::{Document, Sel, SourceInfo};
use crate::player::Player;
use crate::settings::{self, Settings};
use crate::timefmt;
use crate::ui::theme::*;
use crate::ui::wave::{self, ColumnCache, Overview, View, WaveState};
use crate::ui::widgets::{self, BtnKind, Icon, bevel, group_box, icon_button, push_button, thin_bevel};
use crate::wav::{self, WavFormat};

const APP_NAME: &str = "Kool Edit";
const AUDIO_EXTS: &[&str] =
    &["wav", "wave", "mp3", "flac", "ogg", "oga", "m4a", "mp4", "aac", "aif", "aiff", "aifc", "caf", "mka", "webm"];

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    New,
    Open,
    Save,
    SaveAs,
    SaveSelection,
    SetFormat(WavFormat),
    MakeDefault,
    Quit,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    Delete,
    Trim,
    SelectAll,
    SelectView,
    SelectNone,
    Effect(Effect),
    AmplifyDialog,
    TogglePlay,
    Play,
    Stop,
    Pause,
    ToggleLoop,
    ToStart,
    ToEnd,
    ExtendToStart,
    ExtendToEnd,
    Nudge(i32),
    ExtendNudge(i32),
    ZoomIn,
    ZoomOut,
    ZoomFull,
    ZoomSel,
    VZoomIn,
    VZoomOut,
    VZoomReset,
    About,
    Shortcuts,
}

struct Loading {
    path: PathBuf,
    rx: mpsc::Receiver<Result<Document, String>>,
    progress: Arc<AtomicU32>,
    started: Instant,
}

struct Drag {
    anchor: usize,
    press_x: f32,
    moved: bool,
}

struct PlayInfo {
    had_selection: bool,
}

#[derive(Default)]
struct Meter {
    db: [f32; 2],
    hold: [f32; 2],
    hold_at: [f64; 2],
    clipped: [bool; 2],
}

struct Hover {
    frame: usize,
    ch: usize,
    amp: f32,
}

pub struct KoolApp {
    doc: Option<Document>,
    loading: Option<Loading>,
    player: Player,
    play: Option<PlayInfo>,
    paused_at: Option<usize>,
    clipboard: Option<Samples>,
    view: View,
    sel: Sel,
    /// The fixed end when extending a selection with Shift.
    anchor: usize,
    drag: Option<Drag>,
    looping: bool,
    settings: Settings,
    saved_settings: Settings,
    meter: Meter,
    status: Option<(String, Instant)>,
    hover: Option<Hover>,
    wave_rect: Rect,
    zoom_full_pending: bool,
    cols: ColumnCache,
    overview: Overview,
    fields: [String; 6],
    amplify_db: Option<f32>,
    show_about: bool,
    show_keys: bool,
    allow_close: bool,
    pending_open: Option<PathBuf>,
    title: String,
    default_rx: Option<mpsc::Receiver<Result<String, String>>>,
    #[cfg(feature = "devtools")]
    script: Option<crate::devtools::Script>,
    #[cfg(feature = "devtools")]
    shot_path: Option<PathBuf>,
}

impl KoolApp {
    pub fn new(ctx: &egui::Context, initial: Option<PathBuf>, make_default: bool) -> Self {
        let mut app = KoolApp {
            doc: None,
            loading: None,
            player: Player::default(),
            play: None,
            paused_at: None,
            clipboard: None,
            view: View::default(),
            sel: Sel::default(),
            anchor: 0,
            drag: None,
            looping: false,
            settings: Settings::default(),
            saved_settings: Settings::default(),
            meter: Meter { db: [-120.0; 2], hold: [-120.0; 2], ..Default::default() },
            status: None,
            hover: None,
            wave_rect: Rect::from_min_size(pos2(0.0, 0.0), vec2(800.0, 300.0)),
            zoom_full_pending: false,
            cols: ColumnCache::default(),
            overview: Overview::default(),
            fields: Default::default(),
            amplify_db: None,
            show_about: false,
            show_keys: false,
            allow_close: false,
            pending_open: None,
            title: String::new(),
            default_rx: None,
            #[cfg(feature = "devtools")]
            script: crate::devtools::Script::from_env(),
            #[cfg(feature = "devtools")]
            shot_path: None,
        };
        #[cfg(feature = "devtools")]
        let scripted = app.script.is_some();
        #[cfg(not(feature = "devtools"))]
        let scripted = false;
        if scripted {
            // Test runs: don't blast audio or touch the user's preferences.
            app.settings.auto_play = false;
        } else {
            app.settings = Settings::load();
        }
        app.saved_settings = app.settings.clone();
        app.player.set_gain(settings::volume_to_gain(app.settings.volume_db));
        if let Some(path) = initial {
            app.start_loading(path, ctx);
        }
        if make_default {
            app.run(Action::MakeDefault, ctx);
        }
        app
    }

    fn set_status(&mut self, msg: impl Into<String>) {
        self.status = Some((msg.into(), Instant::now()));
    }

    fn error(&mut self, title: &str, msg: &str) {
        self.set_status(msg.to_owned());
        rfd::MessageDialog::new()
            .set_level(rfd::MessageLevel::Error)
            .set_title(title)
            .set_description(msg)
            .set_buttons(rfd::MessageButtons::Ok)
            .show();
    }

    fn len(&self) -> usize {
        self.doc.as_ref().map_or(0, Document::len)
    }

    fn rate(&self) -> u32 {
        self.doc.as_ref().map_or(44100, Document::rate)
    }

    fn secs(&self, frames: usize) -> f64 {
        frames as f64 / self.rate().max(1) as f64
    }

    fn frames(&self, secs: f64) -> usize {
        ((secs.max(0.0) * self.rate() as f64).round() as usize).min(self.len())
    }

    /// True when the whole file fits the window, so edits that change the length should keep it that way.
    fn view_is_full(&self) -> bool {
        let w = self.wave_rect.width();
        self.view.start <= 0.0 && self.view.visible(w) >= self.len() as f64 - 0.5
    }

    fn playhead(&self) -> Option<usize> {
        self.player.is_playing().then(|| self.player.position().min(self.len()))
    }

    // -----------------------------------------------------------------------------------------
    // Files

    fn open_path(&mut self, path: PathBuf, ctx: &egui::Context) {
        if !self.confirm_discard() {
            return;
        }
        self.start_loading(path, ctx);
    }

    fn start_loading(&mut self, path: PathBuf, ctx: &egui::Context) {
        let (tx, rx) = mpsc::channel();
        let progress = Arc::new(AtomicU32::new(0));
        let (p2, path2, ctx2) = (progress.clone(), path.clone(), ctx.clone());
        std::thread::spawn(move || {
            // Build the document (including its peak cache) here, not on the UI thread.
            let doc = decode::load(&path2, &p2).map(|l: Loaded| Document::new(l.samples, Some(path2.clone()), l.info));
            let _ = tx.send(doc);
            ctx2.request_repaint();
        });
        self.loading = Some(Loading { path, rx, progress, started: Instant::now() });
    }

    fn finish_loading(&mut self, loading: Loading, result: Result<Document, String>) {
        match result {
            Ok(doc) => {
                self.stop_now();
                self.paused_at = None;
                self.doc = Some(doc);
                self.sel = Sel::default();
                self.anchor = 0;
                self.view.vzoom = 1.0;
                self.zoom_full_pending = true;
                self.set_status(format!("Opened in {:.2} seconds", loading.started.elapsed().as_secs_f64()));
                if self.settings.auto_play {
                    self.play();
                }
            }
            Err(e) => {
                let name = loading.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                self.error("Couldn't open file", &format!("{name}: {e}"));
            }
        }
    }

    /// Ask to save unsaved changes. Returns false if the user cancelled.
    fn confirm_discard(&mut self) -> bool {
        let Some(doc) = &self.doc else { return true };
        if !doc.is_dirty() {
            return true;
        }
        let answer = rfd::MessageDialog::new()
            .set_level(rfd::MessageLevel::Warning)
            .set_title(APP_NAME)
            .set_description(format!("Save changes to {}?", doc.display_name()))
            .set_buttons(rfd::MessageButtons::YesNoCancelCustom(
                "Save".to_owned(),
                "Don't Save".to_owned(),
                "Cancel".to_owned(),
            ))
            .show();
        match answer {
            rfd::MessageDialogResult::Custom(s) if s == "Save" => self.save(),
            rfd::MessageDialogResult::Yes => self.save(),
            rfd::MessageDialogResult::Custom(s) if s == "Don't Save" => true,
            rfd::MessageDialogResult::No => true,
            _ => false,
        }
    }

    fn save(&mut self) -> bool {
        let Some(doc) = &self.doc else { return false };
        match doc.path.clone() {
            Some(p) if is_wav(&p) => self.write_doc(&p),
            _ => self.save_as(),
        }
    }

    fn save_dialog(&self, title: &str, suffix: &str) -> Option<PathBuf> {
        let doc = self.doc.as_ref()?;
        let stem = doc
            .path
            .as_ref()
            .and_then(|p| p.file_stem())
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Untitled".to_owned());
        let mut dlg = rfd::FileDialog::new()
            .set_title(title)
            .add_filter("WAV audio", &["wav"])
            .set_file_name(format!("{stem}{suffix}.wav"));
        if let Some(dir) = doc.path.as_ref().and_then(|p| p.parent()) {
            dlg = dlg.set_directory(dir);
        }
        dlg.save_file().map(|p| if p.extension().is_none() { p.with_extension("wav") } else { p })
    }

    fn save_as(&mut self) -> bool {
        match self.save_dialog("Save As", "") {
            Some(path) => self.write_doc(&path),
            None => false,
        }
    }

    fn write_doc(&mut self, path: &Path) -> bool {
        let Some(doc) = self.doc.as_mut() else { return false };
        let started = Instant::now();
        let result = wav::save(path, &doc.read(), doc.wav_format);
        match result {
            Ok(()) => {
                doc.path = Some(path.to_owned());
                doc.mark_saved();
                doc.source = SourceInfo {
                    codec: "PCM".to_owned(),
                    bits: Some(doc.wav_format.bytes_per_sample() as u32 * 8),
                };
                let msg = format!("Saved {} ({}) in {:.2} s", doc.display_name(), doc.wav_format.label(), started.elapsed().as_secs_f64());
                self.set_status(msg);
                true
            }
            Err(e) => {
                self.error("Couldn't save", &e);
                false
            }
        }
    }

    fn save_selection(&mut self) {
        let Some(doc) = &self.doc else { return };
        let Some(clip) = doc.copy(self.sel) else { return };
        let fmt = doc.wav_format;
        if let Some(path) = self.save_dialog("Save Selection As", " (selection)") {
            match wav::save(&path, &clip, fmt) {
                Ok(()) => self.set_status(format!("Saved selection to {}", path.display())),
                Err(e) => self.error("Couldn't save", &e),
            }
        }
    }

    // -----------------------------------------------------------------------------------------
    // Transport

    fn play(&mut self) {
        let Some(doc) = &self.doc else { return };
        let len = doc.len();
        if len == 0 {
            return;
        }
        let sel = self.sel.clamp(len);
        let had_selection = !sel.is_empty();
        let (start, end) = if had_selection { (sel.start, sel.end) } else { (sel.start, len) };
        let mut from = self.paused_at.take().filter(|&p| p >= start && p < end).unwrap_or(start);
        if from >= end {
            from = 0;
        }
        let loop_start = if had_selection { sel.start } else { 0 };
        self.player.set_gain(settings::volume_to_gain(self.settings.volume_db));
        match self.player.play(doc.data.clone(), from, end, loop_start, self.looping) {
            Ok(()) => self.play = Some(PlayInfo { had_selection }),
            Err(e) => self.error("Playback", &e),
        }
    }

    /// Stop, moving the cursor to where playback stopped (unless playing a selection).
    fn stop(&mut self) {
        let was_playing = self.player.is_playing();
        let pos = self.player.position().min(self.len());
        let info = self.play.take();
        self.player.stop();
        self.paused_at = None;
        if was_playing && let Some(info) = info && !info.had_selection && !self.settings.return_to_start {
            self.sel = Sel::cursor(pos);
            self.anchor = pos;
        }
    }

    /// Stop without touching the cursor (before edits, loads).
    fn stop_now(&mut self) {
        self.player.stop();
        self.play = None;
    }

    fn pause(&mut self) {
        if self.player.is_playing() {
            self.paused_at = Some(self.player.position().min(self.len()));
            self.stop_now();
        } else if self.paused_at.is_some() {
            self.play();
        }
    }

    fn seek_or_move(&mut self, frame: usize, extend: bool) {
        let len = self.len();
        let frame = frame.min(len);
        if self.player.is_playing() && !extend {
            self.player.retarget(frame, len, 0);
            self.play = Some(PlayInfo { had_selection: false });
        } else {
            self.paused_at = None;
            if extend {
                self.sel = Sel::new(self.anchor, frame);
            } else {
                self.sel = Sel::cursor(frame);
                self.anchor = frame;
            }
        }
        self.view.reveal(frame, len, self.wave_rect.width());
    }

    // -----------------------------------------------------------------------------------------
    // Editing

    fn edit(&mut self, f: impl FnOnce(&mut Document, Sel) -> Option<Sel>) {
        let was_full = self.view_is_full();
        let Some(doc) = self.doc.as_mut() else { return };
        let sel = self.sel.clamp(doc.len());
        // The audio thread outputs silence if it can't get the lock mid-edit, then we stop it:
        // positions shift under an edit, so carrying on would play the wrong audio.
        if let Some(new_sel) = f(doc, sel) {
            self.stop_now();
            self.paused_at = None;
            self.sel = new_sel;
            self.anchor = new_sel.start;
            let len = self.len();
            if was_full {
                self.view.zoom_full(len, self.wave_rect.width());
            } else {
                self.view.clamp(len, self.wave_rect.width());
                self.view.reveal(new_sel.end, len, self.wave_rect.width());
            }
        }
    }

    fn after_history(&mut self, was_full: bool) {
        let (len, width) = (self.len(), self.wave_rect.width());
        if was_full {
            self.view.zoom_full(len, width);
        } else {
            self.view.clamp(len, width);
        }
    }

    fn copy(&mut self, ctx: &egui::Context) {
        let Some(clip) = self.doc.as_ref().and_then(|d| d.copy(self.sel)) else { return };
        let secs = clip.secs(clip.len());
        self.clipboard = Some(clip);
        // egui only delivers ⌘V when the system clipboard holds text, so leave a note there.
        ctx.copy_text(format!("[Kool Edit audio clip, {}]", timefmt::format(secs, 3)));
        self.set_status(format!("Copied {}", timefmt::format(secs, 3)));
    }

    fn paste(&mut self) {
        let Some(clip) = self.clipboard.clone() else { return };
        if self.doc.is_none() {
            self.doc = Some(Document::new(Samples::silent(clip.rate, clip.n_chans()), None, new_source()));
            self.sel = Sel::default();
            self.zoom_full_pending = true;
        }
        let was_empty = self.len() == 0;
        self.edit(|d, sel| d.paste(sel, &clip));
        if was_empty {
            self.zoom_full_pending = true;
        }
    }

    fn run(&mut self, action: Action, ctx: &egui::Context) {
        #[cfg(feature = "devtools")]
        eprintln!("devtools: action {action:?} at frame {}", ctx.cumulative_frame_nr());
        let len = self.len();
        let width = self.wave_rect.width();
        let vis = self.view.visible(width);
        match action {
            Action::New => {
                if self.confirm_discard() {
                    self.stop_now();
                    self.doc = Some(Document::new(Samples::silent(44100, 2), None, new_source()));
                    self.sel = Sel::default();
                    self.paused_at = None;
                    self.zoom_full_pending = true;
                }
            }
            Action::Open => {
                let mut dlg = rfd::FileDialog::new().set_title("Open").add_filter("Audio files", AUDIO_EXTS);
                if let Some(dir) = self.doc.as_ref().and_then(|d| d.path.as_ref()).and_then(|p| p.parent()) {
                    dlg = dlg.set_directory(dir);
                }
                if let Some(path) = dlg.pick_file() {
                    self.open_path(path, ctx);
                }
            }
            Action::Save => {
                self.save();
            }
            Action::SaveAs => {
                self.save_as();
            }
            Action::SaveSelection => self.save_selection(),
            Action::SetFormat(f) => {
                if let Some(d) = self.doc.as_mut() {
                    d.wav_format = f;
                }
            }
            Action::MakeDefault => {
                #[cfg(target_os = "macos")]
                {
                    let (tx, rx) = mpsc::channel();
                    let ctx2 = ctx.clone();
                    std::thread::spawn(move || {
                        let _ = tx.send(crate::macos::make_default_player());
                        ctx2.request_repaint();
                    });
                    self.default_rx = Some(rx);
                    self.set_status("Registering with Launch Services…");
                }
            }
            Action::Quit => {
                if self.confirm_discard() {
                    self.allow_close = true;
                    self.stop_now();
                    ctx.send_viewport_cmd(ViewportCommand::Close);
                }
            }
            Action::Undo => {
                let was_full = self.view_is_full();
                let sel = self.doc.as_mut().and_then(|d| {
                    let name = d.undo_name().map(str::to_owned);
                    d.undo().map(|s| (s, name))
                });
                if let Some((s, name)) = sel {
                    self.stop_now();
                    self.paused_at = None;
                    self.sel = s.clamp(self.len());
                    self.anchor = self.sel.start;
                    self.after_history(was_full);
                    self.set_status(format!("Undid {}", name.unwrap_or_default()));
                }
            }
            Action::Redo => {
                let was_full = self.view_is_full();
                let sel = self.doc.as_mut().and_then(|d| {
                    let name = d.redo_name().map(str::to_owned);
                    d.redo().map(|s| (s, name))
                });
                if let Some((s, name)) = sel {
                    self.stop_now();
                    self.paused_at = None;
                    self.sel = s.clamp(self.len());
                    self.anchor = self.sel.start;
                    self.after_history(was_full);
                    self.set_status(format!("Redid {}", name.unwrap_or_default()));
                }
            }
            Action::Cut => {
                let mut clip = None;
                self.edit(|d, sel| d.cut(sel).map(|(c, s)| {
                    clip = Some(c);
                    s
                }));
                if let Some(c) = clip {
                    let secs = c.secs(c.len());
                    self.clipboard = Some(c);
                    ctx.copy_text(format!("[Kool Edit audio clip, {}]", timefmt::format(secs, 3)));
                    self.set_status(format!("Cut {}", timefmt::format(secs, 3)));
                }
            }
            Action::Copy => self.copy(ctx),
            Action::Paste => self.paste(),
            Action::Delete => self.edit(|d, sel| d.delete(sel)),
            Action::Trim => self.edit(|d, sel| d.trim(sel)),
            Action::Effect(fx) => self.edit(|d, sel| d.effect(sel, fx)),
            Action::AmplifyDialog => {
                if self.doc.is_some() {
                    self.amplify_db = Some(self.amplify_db.unwrap_or(3.0));
                }
            }
            Action::SelectAll => {
                self.sel = Sel::new(0, len);
                self.anchor = 0;
                self.paused_at = None;
            }
            Action::SelectView => {
                let a = self.view.start.max(0.0) as usize;
                self.sel = Sel::new(a, ((self.view.start + vis) as usize).min(len));
                self.anchor = a;
                self.paused_at = None;
            }
            Action::SelectNone => {
                self.sel = Sel::cursor(self.sel.start);
                self.anchor = self.sel.start;
            }
            Action::TogglePlay => {
                if self.player.is_playing() {
                    self.stop();
                } else {
                    self.play();
                }
            }
            Action::Play => {
                if !self.player.is_playing() {
                    self.play();
                }
            }
            Action::Stop => self.stop(),
            Action::Pause => self.pause(),
            Action::ToggleLoop => self.looping = !self.looping,
            Action::ToStart => self.seek_or_move(0, false),
            Action::ToEnd => {
                if self.player.is_playing() {
                    self.stop_now();
                }
                self.seek_or_move(len, false);
            }
            Action::ExtendToStart => self.seek_or_move(0, true),
            Action::ExtendToEnd => self.seek_or_move(len, true),
            Action::Nudge(dir) | Action::ExtendNudge(dir) => {
                let extend = matches!(action, Action::ExtendNudge(_));
                if self.player.is_playing() && !extend {
                    // Skip ±5 seconds while playing.
                    let step = self.rate() as i64 * 5 * dir as i64;
                    let pos = (self.player.position() as i64 + step).clamp(0, len as i64) as usize;
                    self.player.seek(pos);
                } else {
                    let step = ((vis / 40.0).max(1.0) as i64) * dir as i64;
                    let moving = if extend && self.sel.start == self.anchor { self.sel.end } else { self.sel.start };
                    let target = (moving as i64 + step).clamp(0, len as i64) as usize;
                    self.seek_or_move(target, extend);
                }
            }
            Action::ZoomIn | Action::ZoomOut => {
                let factor = if action == Action::ZoomIn { 2.0 } else { 0.5 };
                let anchor = self.zoom_anchor();
                let rect = self.wave_rect;
                self.view.zoom_at(factor, anchor, rect, len);
            }
            Action::ZoomFull => self.view.zoom_full(len, width),
            Action::ZoomSel => {
                if !self.sel.is_empty() {
                    self.view.show_range(self.sel.start, self.sel.end, len, width);
                }
            }
            Action::VZoomIn => self.view.vzoom = (self.view.vzoom * 1.5).min(64.0),
            Action::VZoomOut => self.view.vzoom = (self.view.vzoom / 1.5).max(1.0),
            Action::VZoomReset => self.view.vzoom = 1.0,
            Action::About => self.show_about = true,
            Action::Shortcuts => self.show_keys = true,
        }
    }

    /// Zoom around the playhead, else the selection/cursor if visible, else the centre.
    fn zoom_anchor(&self) -> f64 {
        let vis = self.view.visible(self.wave_rect.width());
        let in_view = |f: f64| f >= self.view.start && f <= self.view.start + vis;
        let candidates = [
            self.playhead().map(|p| p as f64),
            (!self.sel.is_empty()).then(|| (self.sel.start + self.sel.end) as f64 / 2.0),
            Some(self.sel.start as f64),
        ];
        candidates.into_iter().flatten().find(|&f| in_view(f)).unwrap_or(self.view.start + vis / 2.0)
    }

    // -----------------------------------------------------------------------------------------
    // Per-frame bookkeeping

    fn poll(&mut self, ctx: &egui::Context, actions: &mut Vec<Action>) {
        // Keep the audio thread's gain in step with the saved fader, including while a stream
        // is already running. The slider also publishes immediately so a drag isn't a frame late.
        self.player.set_gain(settings::volume_to_gain(self.settings.volume_db));
        #[cfg(target_os = "macos")]
        {
            if let Some(path) = crate::macos::take_open_requests().pop() {
                self.pending_open = Some(path);
                ctx.send_viewport_cmd(ViewportCommand::Focus);
            }
            if crate::macos::take_quit_request() {
                actions.push(Action::Quit);
            }
        }
        if let Some(path) = ctx.input(|i| i.raw.dropped_files.iter().map(|f| f.path().to_owned()).find(|p| !p.as_os_str().is_empty())) {
            self.pending_open = Some(path);
        }
        if let Some(path) = self.pending_open.take() {
            self.open_path(path, ctx);
        }
        if let Some(loading) = &self.loading {
            match loading.rx.try_recv() {
                Ok(result) => {
                    let loading = self.loading.take().expect("checked above");
                    self.finish_loading(loading, result);
                }
                Err(mpsc::TryRecvError::Empty) => {}
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.loading = None;
                    self.error("Couldn't open file", "The decoder crashed.");
                }
            }
        }
        if let Some(rx) = &self.default_rx
            && let Ok(result) = rx.try_recv()
        {
            self.default_rx = None;
            match result {
                Ok(msg) => self.set_status(msg),
                Err(e) => self.error("Make Default Audio Player", &e),
            }
        }

        self.player.set_looping(self.looping);
        if self.player.finished() {
            // Reached the end: leave the cursor where playback started, like Cool Edit.
            self.stop_now();
        }

        // Meters: instant attack, ~24 dB/s release, 1.5 s peak hold.
        let now = ctx.input(|i| i.time);
        let dt = ctx.input(|i| i.stable_dt).min(0.1);
        let peaks = self.player.take_peaks();
        let mono = self.doc.as_ref().is_some_and(|d| d.n_chans() == 1);
        for ch in 0..2 {
            let lin = if mono { peaks[0] } else { peaks[ch] };
            let db = widgets::to_db(lin);
            self.meter.db[ch] = db.max(self.meter.db[ch] - 24.0 * dt);
            if db >= self.meter.hold[ch] {
                self.meter.hold[ch] = db;
                self.meter.hold_at[ch] = now;
            } else if now - self.meter.hold_at[ch] > 1.5 {
                self.meter.hold[ch] -= 20.0 * dt;
            }
            if lin >= 0.999 {
                self.meter.clipped[ch] = true;
            }
        }

        if ctx.input(|i| i.viewport().close_requested()) && !self.allow_close {
            if self.confirm_discard() {
                self.allow_close = true;
                self.stop_now();
            } else {
                ctx.send_viewport_cmd(ViewportCommand::CancelClose);
            }
        }
    }

    fn shortcuts(&mut self, ctx: &egui::Context) -> Vec<Action> {
        if ctx.text_edit_focused() {
            return Vec::new();
        }
        ctx.input_mut(|i| {
            let mut a = Vec::new();
            for e in &i.events {
                match e {
                    Event::Copy => a.push(Action::Copy),
                    Event::Cut => a.push(Action::Cut),
                    Event::Paste(_) => a.push(Action::Paste),
                    _ => {}
                }
            }
            let cmd = Modifiers::COMMAND;
            let cmd_shift = Modifiers::COMMAND | Modifiers::SHIFT;
            let none = Modifiers::NONE;
            let shift = i.modifiers.shift;
            // Shifted variants first: consume_key ignores extra Shift.
            let table: &[(Modifiers, Key, Action)] = &[
                (cmd_shift, Key::Z, Action::Redo),
                (cmd, Key::Z, Action::Undo),
                (cmd, Key::Y, Action::Redo),
                (cmd_shift, Key::S, Action::SaveAs),
                (cmd, Key::S, Action::Save),
                (cmd, Key::O, Action::Open),
                (cmd, Key::N, Action::New),
                (cmd, Key::T, Action::Trim),
                (cmd, Key::A, Action::SelectAll),
                (cmd, Key::E, Action::ZoomSel),
                (cmd, Key::Num0, Action::ZoomFull),
                (cmd, Key::Equals, Action::ZoomIn),
                (cmd, Key::Plus, Action::ZoomIn),
                (cmd, Key::Minus, Action::ZoomOut),
                (cmd, Key::X, Action::Cut),
                (cmd, Key::C, Action::Copy),
                (cmd, Key::V, Action::Paste),
                (cmd, Key::Q, Action::Quit),
                (none, Key::Space, Action::TogglePlay),
                (none, Key::Delete, Action::Delete),
                (none, Key::Backspace, Action::Delete),
                (none, Key::Escape, Action::SelectNone),
                (none, Key::Equals, Action::ZoomIn),
                (none, Key::Plus, Action::ZoomIn),
                (none, Key::Minus, Action::ZoomOut),
                (none, Key::L, Action::ToggleLoop),
                (none, Key::P, Action::Pause),
            ];
            for &(m, k, act) in table {
                if i.consume_key(m, k) {
                    a.push(act);
                }
            }
            if i.consume_key(none, Key::Home) {
                a.push(if shift { Action::ExtendToStart } else { Action::ToStart });
            }
            if i.consume_key(none, Key::End) {
                a.push(if shift { Action::ExtendToEnd } else { Action::ToEnd });
            }
            for (k, dir) in [(Key::ArrowLeft, -1), (Key::ArrowRight, 1)] {
                if i.consume_key(none, k) {
                    a.push(if shift { Action::ExtendNudge(dir) } else { Action::Nudge(dir) });
                }
            }
            a
        })
    }

    fn update_title(&mut self, ctx: &egui::Context) {
        let title = if let Some(l) = &self.loading {
            format!("{APP_NAME} - Loading {}…", l.path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default())
        } else if let Some(d) = &self.doc {
            format!("{APP_NAME} - {}{}", d.display_name(), if d.is_dirty() { " *" } else { "" })
        } else {
            APP_NAME.to_owned()
        };
        if title != self.title {
            ctx.send_viewport_cmd(ViewportCommand::Title(title.clone()));
            self.title = title;
        }
    }

    // -----------------------------------------------------------------------------------------
    // Layout

    fn menu_bar(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        let has_doc = self.doc.is_some();
        let has_audio = self.len() > 0;
        let has_sel = has_doc && !self.sel.is_empty();
        let has_clip = self.clipboard.is_some();
        let undo = self.doc.as_ref().and_then(|d| d.undo_name()).map(str::to_owned);
        let redo = self.doc.as_ref().and_then(|d| d.redo_name()).map(str::to_owned);
        let fmt = self.doc.as_ref().map(|d| d.wav_format);

        egui::MenuBar::new().ui(ui, |ui| {
            ui.menu_button("File", |ui| {
                item(ui, actions, "New", "⌘N", true, Action::New);
                item(ui, actions, "Open…", "⌘O", true, Action::Open);
                ui.separator();
                item(ui, actions, "Save", "⌘S", has_doc, Action::Save);
                item(ui, actions, "Save As…", "⇧⌘S", has_doc, Action::SaveAs);
                item(ui, actions, "Save Selection As…", "", has_sel, Action::SaveSelection);
                ui.add_enabled_ui(has_doc, |ui| {
                    ui.menu_button("WAV Format", |ui| {
                        for f in WavFormat::ALL {
                            if ui.radio(fmt == Some(f), f.label()).clicked() {
                                actions.push(Action::SetFormat(f));
                                ui.close();
                            }
                        }
                    });
                });
                if cfg!(target_os = "macos") {
                    ui.separator();
                    item(ui, actions, "Make Default Audio Player", "", true, Action::MakeDefault);
                }
                ui.separator();
                item(ui, actions, "Quit", "⌘Q", true, Action::Quit);
            });
            ui.menu_button("Edit", |ui| {
                let u = undo.as_deref().map_or("Undo".to_owned(), |n| format!("Undo {n}"));
                let r = redo.as_deref().map_or("Redo".to_owned(), |n| format!("Redo {n}"));
                item(ui, actions, &u, "⌘Z", undo.is_some(), Action::Undo);
                item(ui, actions, &r, "⇧⌘Z", redo.is_some(), Action::Redo);
                ui.separator();
                item(ui, actions, "Cut", "⌘X", has_sel, Action::Cut);
                item(ui, actions, "Copy", "⌘C", has_sel, Action::Copy);
                item(ui, actions, "Paste", "⌘V", has_clip, Action::Paste);
                item(ui, actions, "Delete Selection", "⌫", has_sel, Action::Delete);
                item(ui, actions, "Trim", "⌘T", has_sel, Action::Trim);
                ui.separator();
                item(ui, actions, "Select Entire Wave", "⌘A", has_audio, Action::SelectAll);
                item(ui, actions, "Select Visible", "Dbl-click", has_audio, Action::SelectView);
                item(ui, actions, "Deselect", "Esc", has_sel, Action::SelectNone);
            });
            ui.menu_button("View", |ui| {
                item(ui, actions, "Zoom In", "=", has_audio, Action::ZoomIn);
                item(ui, actions, "Zoom Out", "-", has_audio, Action::ZoomOut);
                item(ui, actions, "Zoom Full", "⌘0", has_audio, Action::ZoomFull);
                item(ui, actions, "Zoom to Selection", "⌘E", has_sel, Action::ZoomSel);
                ui.separator();
                item(ui, actions, "Zoom In Vertically", "", has_audio, Action::VZoomIn);
                item(ui, actions, "Zoom Out Vertically", "", has_audio, Action::VZoomOut);
                item(ui, actions, "Reset Vertical Zoom", "", has_audio, Action::VZoomReset);
                ui.separator();
                ui.checkbox(&mut self.settings.follow, "Follow Playback");
            });
            ui.menu_button("Transport", |ui| {
                item(ui, actions, "Play / Stop", "Space", has_audio, Action::TogglePlay);
                item(ui, actions, "Pause", "P", has_audio, Action::Pause);
                item(ui, actions, "Go to Beginning", "Home", has_audio, Action::ToStart);
                item(ui, actions, "Go to End", "End", has_audio, Action::ToEnd);
                ui.separator();
                ui.checkbox(&mut self.looping, "Loop Playback  (L)");
                ui.checkbox(&mut self.settings.auto_play, "Auto-Play on Open");
                ui.checkbox(&mut self.settings.return_to_start, "Return to Start on Stop");
            });
            ui.menu_button("Effects", |ui| {
                let label = if has_sel { "selection" } else { "entire wave" };
                ui.label(egui::RichText::new(format!("Applies to {label}")).small().color(DISABLED_TEXT));
                for fx in [Effect::Silence, Effect::FadeIn, Effect::FadeOut, Effect::Normalize, Effect::Reverse, Effect::Invert] {
                    let name = if fx == Effect::Normalize { "Normalize (-0.1 dB)" } else { fx.name() };
                    item(ui, actions, name, "", has_audio, Action::Effect(fx));
                }
                item(ui, actions, "Amplify…", "", has_audio, Action::AmplifyDialog);
            });
            ui.menu_button("Help", |ui| {
                item(ui, actions, "Keyboard Shortcuts", "", true, Action::Shortcuts);
                item(ui, actions, "About Kool Edit", "", true, Action::About);
            });
        });
    }

    fn toolbar(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        let has_doc = self.doc.is_some();
        let has_audio = self.len() > 0;
        let has_sel = has_doc && !self.sel.is_empty();
        let can_undo = self.doc.as_ref().is_some_and(|d| d.undo_name().is_some());
        let can_redo = self.doc.as_ref().is_some_and(|d| d.redo_name().is_some());
        let sz = vec2(26.0, 24.0);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 1.0;
            let mut b = |ui: &mut Ui, icon, enabled, tip: &str, act| {
                if icon_button(ui, icon, sz, BtnKind::Flat, enabled, false, tip).clicked() {
                    actions.push(act);
                }
            };
            b(ui, Icon::New, true, "New (⌘N)", Action::New);
            b(ui, Icon::Open, true, "Open (⌘O)", Action::Open);
            b(ui, Icon::Save, has_doc, "Save (⌘S)", Action::Save);
            separator(ui);
            b(ui, Icon::Undo, can_undo, "Undo (⌘Z)", Action::Undo);
            b(ui, Icon::Redo, can_redo, "Redo (⇧⌘Z)", Action::Redo);
            separator(ui);
            b(ui, Icon::Cut, has_sel, "Cut (⌘X)", Action::Cut);
            b(ui, Icon::Copy, has_sel, "Copy (⌘C)", Action::Copy);
            b(ui, Icon::Paste, self.clipboard.is_some(), "Paste (⌘V)", Action::Paste);
            b(ui, Icon::Delete, has_sel, "Delete Selection (⌫)", Action::Delete);
            b(ui, Icon::Trim, has_sel, "Trim to Selection (⌘T)", Action::Trim);
            separator(ui);
            b(ui, Icon::ZoomIn, has_audio, "Zoom In (=)", Action::ZoomIn);
            b(ui, Icon::ZoomOut, has_audio, "Zoom Out (-)", Action::ZoomOut);
            b(ui, Icon::ZoomFull, has_audio, "Zoom Full (⌘0)", Action::ZoomFull);
            b(ui, Icon::ZoomSel, has_sel, "Zoom to Selection (⌘E)", Action::ZoomSel);
        });
    }

    fn controls(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        let has_audio = self.len() > 0;
        let has_sel = has_audio && !self.sel.is_empty();
        let playing = self.player.is_playing();
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing = vec2(2.0, 2.0);
            group_box(ui, "Transport", |ui| {
                let sz = vec2(34.0, 25.0);
                let b = |ui: &mut Ui, icon, checked: bool, tip: &str| {
                    icon_button(ui, icon, sz, BtnKind::Raised, has_audio, checked, tip)
                };
                ui.vertical(|ui| {
                    ui.horizontal(|ui| {
                        if b(ui, Icon::Stop, false, "Stop (Space)").clicked() {
                            actions.push(Action::Stop);
                        }
                        if b(ui, Icon::Play, playing, "Play (Space)").clicked() {
                            actions.push(Action::Play);
                        }
                        if b(ui, Icon::Pause, self.paused_at.is_some(), "Pause (P)").clicked() {
                            actions.push(Action::Pause);
                        }
                        if b(ui, Icon::Loop, self.looping, "Loop Playback (L)").clicked() {
                            actions.push(Action::ToggleLoop);
                        }
                    });
                    ui.horizontal(|ui| {
                        if b(ui, Icon::ToStart, false, "Go to Beginning (Home)").clicked() {
                            actions.push(Action::ToStart);
                        }
                        let rw = b(ui, Icon::Rewind, false, "Rewind (hold)");
                        let ff = b(ui, Icon::FastFwd, false, "Fast Forward (hold)");
                        for (r, dir) in [(rw, -1.0), (ff, 1.0)] {
                            if r.is_pointer_button_down_on() {
                                self.scrub(ui.ctx(), dir);
                            }
                        }
                        if b(ui, Icon::ToEnd, false, "Go to End (End)").clicked() {
                            actions.push(Action::ToEnd);
                        }
                    });
                });
            });
            self.volume_box(ui);
            group_box(ui, "Zoom", |ui| {
                let sz = vec2(30.0, 25.0);
                let mut b = |ui: &mut Ui, icon, enabled: bool, tip: &str, act| {
                    if icon_button(ui, icon, sz, BtnKind::Raised, enabled, false, tip).clicked() {
                        actions.push(act);
                    }
                };
                ui.vertical(|ui| {
                    ui.horizontal(|ui| {
                        b(ui, Icon::ZoomIn, has_audio, "Zoom In (=)", Action::ZoomIn);
                        b(ui, Icon::ZoomOut, has_audio, "Zoom Out (-)", Action::ZoomOut);
                        b(ui, Icon::ZoomFull, has_audio, "Zoom Full (⌘0)", Action::ZoomFull);
                    });
                    ui.horizontal(|ui| {
                        b(ui, Icon::ZoomSel, has_sel, "Zoom to Selection (⌘E)", Action::ZoomSel);
                        b(ui, Icon::ZoomInV, has_audio, "Zoom In Vertically", Action::VZoomIn);
                        b(ui, Icon::ZoomOutV, has_audio, "Zoom Out Vertically", Action::VZoomOut);
                    });
                });
            });
            ui.add_space(4.0);
            self.lcd(ui);
            ui.add_space(4.0);
            group_box(ui, "Selection / View", |ui| self.time_fields(ui));
        });
    }

    /// Master output fader, sitting in the transport row. Double-click returns to 0 dB.
    fn volume_box(&mut self, ui: &mut Ui) {
        group_box(ui, "Volume", |ui| {
            // Fixed slot, the same height as the two transport-button rows. A child
            // `with_layout` would otherwise claim the rest of the controls row.
            let (rect, _) = ui.allocate_exact_size(vec2(146.0, 52.0), Sense::hover());
            let mut child = ui.new_child(
                egui::UiBuilder::new().max_rect(rect).layout(egui::Layout::top_down(egui::Align::Center)),
            );
            child.spacing_mut().item_spacing.y = 2.0;
            child.add_space(6.0);
            let text = settings::format_volume(self.settings.volume_db);
            let (label, _) = child.allocate_exact_size(vec2(138.0, 15.0), Sense::hover());
            child.painter().text(label.center(), Align2::CENTER_CENTER, text, FontId::proportional(12.0), TEXT);
            let mut db = self.settings.volume_db;
            let resp = widgets::volume_slider(
                &mut child,
                &mut db,
                settings::VOLUME_MIN_DB,
                settings::VOLUME_MAX_DB,
                0.0,
                vec2(138.0, 22.0),
            );
            db = settings::snap_volume_db(db);
            if db != self.settings.volume_db {
                self.settings.volume_db = db;
                self.player.set_gain(settings::volume_to_gain(db));
            }
            resp.on_hover_text("Master volume, silence to +6 dB. Double-click to reset to 0 dB.");
        });
    }

    /// Hold-to-scrub for the rewind/fast-forward buttons.
    fn scrub(&mut self, ctx: &egui::Context, dir: f64) {
        let len = self.len();
        let dt = ctx.input(|i| i.stable_dt).min(0.1) as f64;
        let speed = (self.view.visible(self.wave_rect.width()) * 0.5).max(self.rate() as f64 * 4.0);
        let delta = (dir * speed * dt) as i64;
        if self.player.is_playing() {
            let pos = (self.player.position() as i64 + delta).clamp(0, len as i64) as usize;
            self.player.seek(pos);
            self.view.reveal(pos, len, self.wave_rect.width());
        } else {
            let pos = (self.sel.start as i64 + delta).clamp(0, len as i64) as usize;
            self.seek_or_move(pos, false);
        }
        ctx.request_repaint();
    }

    fn lcd(&mut self, ui: &mut Ui) {
        let (rect, _) = ui.allocate_exact_size(vec2(236.0, 66.0), Sense::hover());
        let rect = rect.translate(vec2(0.0, 3.0));
        let p = ui.painter();
        p.rect_filled(rect, CornerRadius::ZERO, LCD_BG);
        bevel(p, rect, false);
        let shown = self.playhead().or(self.paused_at).unwrap_or(self.sel.start);
        let text = timefmt::format(self.secs(shown), 3);
        let h = 34.0;
        let w = widgets::lcd_width(&text, h);
        let origin = pos2(rect.center().x - w / 2.0, rect.top() + 18.0);
        widgets::lcd(p, origin, h, &text, LCD_ON, LCD_OFF);
        let state = if self.player.is_playing() {
            "PLAY"
        } else if self.paused_at.is_some() {
            "PAUSE"
        } else {
            "STOP"
        };
        let small = FontId::proportional(9.5);
        p.text(rect.left_top() + vec2(7.0, 5.0), Align2::LEFT_TOP, state, small.clone(), LCD_ON);
        p.text(
            rect.left_top() + vec2(48.0, 5.0),
            Align2::LEFT_TOP,
            "LOOP",
            small.clone(),
            if self.looping { LCD_ON } else { LCD_OFF },
        );
        if let Some(d) = &self.doc {
            p.text(rect.right_top() + vec2(-7.0, 5.0), Align2::RIGHT_TOP, format!("{} Hz", d.rate()), small, LCD_ON);
        }
    }

    fn time_fields(&mut self, ui: &mut Ui) {
        let enabled = self.len() > 0;
        let width = self.wave_rect.width();
        let len = self.len();
        let view_start = self.view.start.max(0.0) as usize;
        let view_end = ((self.view.start + self.view.visible(width)) as usize).min(len);
        let values = [
            self.sel.start,
            self.sel.end,
            self.sel.len(),
            view_start,
            view_end,
            view_end.saturating_sub(view_start),
        ];
        let mut committed: Option<(usize, f64)> = None;
        egui::Grid::new("time_grid").spacing(vec2(4.0, 3.0)).show(ui, |ui| {
            ui.label("");
            for h in ["Begin", "End", "Length"] {
                ui.label(egui::RichText::new(h).size(11.5));
            }
            ui.end_row();
            for (row, name) in ["Sel", "View"].into_iter().enumerate() {
                ui.label(egui::RichText::new(name).size(11.5));
                for col in 0..3 {
                    let idx = row * 3 + col;
                    let id = egui::Id::new(("time_field", idx));
                    if !ui.memory(|m| m.has_focus(id)) {
                        self.fields[idx] = timefmt::format(self.secs(values[idx]), 3);
                    }
                    let edit = egui::TextEdit::singleline(&mut self.fields[idx])
                        .id(id)
                        .font(egui::TextStyle::Monospace)
                        .horizontal_align(egui::Align::RIGHT);
                    let resp = ui.add_enabled_ui(enabled, |ui| ui.add_sized(vec2(84.0, 20.0), edit)).inner;
                    if resp.lost_focus()
                        && let Some(secs) = timefmt::parse(&self.fields[idx])
                    {
                        committed = Some((idx, secs));
                    }
                }
                ui.end_row();
            }
        });
        if let Some((idx, secs)) = committed {
            let f = self.frames(secs);
            match idx {
                0 => self.sel = Sel::new(f, self.sel.end.max(f)),
                1 => self.sel = Sel::new(self.sel.start, f),
                2 => self.sel = Sel::new(self.sel.start, (self.sel.start + f).min(len)),
                3 => self.view.start = f as f64,
                4 => self.view.spp = (f.saturating_sub(view_start)).max(1) as f64 / width as f64,
                _ => self.view.spp = f.max(1) as f64 / width as f64,
            }
            if idx < 3 {
                self.anchor = self.sel.start;
                self.paused_at = None;
            }
            self.view.clamp(len, width);
        }
    }

    fn status_bar(&mut self, ui: &mut Ui) {
        let rect = ui.max_rect();
        let p = ui.painter();
        let font = FontId::proportional(12.0);
        let mut fields: Vec<(f32, String)> = Vec::new();
        if let Some(d) = &self.doc {
            let n = d.n_chans();
            let ch = match n {
                1 => "Mono".to_owned(),
                2 => "Stereo".to_owned(),
                n => format!("{n} ch"),
            };
            let depth = match d.source.bits {
                Some(b) => format!("{b}-bit"),
                None => d.source.codec.clone(),
            };
            let bytes = d.len() as u64 * n as u64 * d.wav_format.bytes_per_sample();
            fields.push((150.0, format!("{} Hz • {} • {}", d.rate(), depth, ch)));
            fields.push((84.0, format!("{:.2} MB", bytes as f64 / 1_048_576.0)));
            fields.push((92.0, timefmt::format(d.read().secs(d.len()), 3)));
        }
        let hover = self.hover.as_ref().map(|h| {
            let name = match (self.doc.as_ref().map_or(1, |d| d.n_chans()), h.ch) {
                (1, _) => "M",
                (2, 0) => "L",
                (2, _) => "R",
                _ => "Ch",
            };
            let db = widgets::to_db(h.amp.abs());
            let db = if db < -100.0 { "-∞".to_owned() } else { format!("{db:.1}") };
            format!("{name}: {db} dB @ {}", timefmt::format(self.secs(h.frame), 3))
        });
        fields.insert(0, (190.0, hover.unwrap_or_default()));

        let mut x = rect.right() - 2.0;
        let mut boxes = Vec::new();
        for (w, text) in fields.iter().rev() {
            let r = Rect::from_min_max(pos2(x - w, rect.top() + 2.0), pos2(x, rect.bottom() - 2.0));
            boxes.push((r, text.clone()));
            x -= w + 2.0;
        }
        let msg_rect = Rect::from_min_max(pos2(rect.left() + 2.0, rect.top() + 2.0), pos2(x, rect.bottom() - 2.0));
        let msg = match (&self.loading, &self.status) {
            (Some(l), _) => format!("Loading… {}%", l.progress.load(Ordering::Relaxed) / 10),
            (None, Some((m, t))) if t.elapsed().as_secs() < 8 => m.clone(),
            _ if self.player.is_playing() => if self.looping { "Playing (looped)".to_owned() } else { "Playing".to_owned() },
            _ if self.paused_at.is_some() => "Paused".to_owned(),
            _ => "Stopped".to_owned(),
        };
        boxes.push((msg_rect, msg));
        for (r, text) in boxes {
            thin_bevel(p, r, false);
            p.with_clip_rect(r.shrink(1.0)).text(pos2(r.left() + 5.0, r.center().y), Align2::LEFT_CENTER, text, font.clone(), TEXT);
        }
    }

    fn meters(&mut self, ui: &mut Ui) {
        let rect = ui.max_rect().shrink2(vec2(3.0, 2.0));
        let resp = ui.interact(rect, ui.id().with("meter"), Sense::click());
        if resp.clicked() {
            self.meter.clipped = [false; 2];
        }
        let p = ui.painter();
        bevel(p, rect, false);
        widgets::meter(p, rect.shrink(2.0), self.meter.db, self.meter.hold, self.meter.clipped);
        resp.on_hover_text("Output level, after the master volume. Click to reset the clip lights.");
    }

    fn central(&mut self, ui: &mut Ui, actions: &mut Vec<Action>) {
        let full = ui.max_rect();
        let (ov_h, tr_h, sb_h, ar_w) = (26.0, 20.0, 17.0, 42.0);
        let ov_rect = Rect::from_min_max(pos2(full.left() + 3.0, full.top() + 3.0), pos2(full.right() - 3.0, full.top() + 3.0 + ov_h));
        let sb_y = full.bottom() - 3.0 - sb_h;
        let frame = Rect::from_min_max(pos2(full.left() + 3.0, ov_rect.bottom() + 3.0), pos2(full.right() - 3.0 - ar_w, sb_y - tr_h));
        let wave_rect = frame.shrink(2.0);
        let tr_rect = Rect::from_min_max(pos2(wave_rect.left(), frame.bottom()), pos2(wave_rect.right(), sb_y));
        let sb_rect = Rect::from_min_max(pos2(frame.left(), sb_y), pos2(frame.right(), full.bottom() - 3.0));
        let amp_rect = Rect::from_min_max(pos2(frame.right() + 1.0, wave_rect.top()), pos2(full.right() - 3.0, wave_rect.bottom()));
        let corner = Rect::from_min_max(pos2(amp_rect.left(), frame.bottom()), pos2(amp_rect.right(), full.bottom() - 3.0));

        let len = self.len();
        let old_width = self.wave_rect.width();
        let was_full = (self.view.spp - View::max_spp(len, old_width)).abs() < 1e-9 && self.view.start == 0.0;
        self.wave_rect = wave_rect;
        if self.zoom_full_pending || (was_full && old_width != wave_rect.width()) {
            self.view.zoom_full(len, wave_rect.width());
            self.zoom_full_pending = false;
        }
        self.view.clamp(len, wave_rect.width());

        let painter = ui.painter().clone();
        bevel(&painter, frame, false);
        painter.rect_filled(corner, CornerRadius::ZERO, FACE);
        painter.text(corner.center(), Align2::CENTER_CENTER, "hms", FontId::proportional(10.5), NAVY);

        let Some(_) = &self.doc else {
            painter.rect_filled(wave_rect, CornerRadius::ZERO, WAVE_BG);
            bevel(&painter, ov_rect, false);
            painter.rect_filled(ov_rect.shrink(2.0), CornerRadius::ZERO, WAVE_BG);
            painter.rect_filled(amp_rect, CornerRadius::ZERO, FACE);
            painter.rect_filled(tr_rect, CornerRadius::ZERO, FACE);
            painter.rect_filled(sb_rect, CornerRadius::ZERO, LIGHT);
            let msg = match &self.loading {
                Some(l) => format!(
                    "Loading {}…  {}%",
                    l.path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default(),
                    l.progress.load(Ordering::Relaxed) / 10
                ),
                None => "Drop an audio file here, or press ⌘O to open one".to_owned(),
            };
            painter.text(wave_rect.center(), Align2::CENTER_CENTER, msg, FontId::proportional(16.0), WAVE_FG);
            painter.text(
                wave_rect.center() + vec2(0.0, 24.0),
                Align2::CENTER_CENTER,
                "WAV • MP3 • FLAC • OGG • M4A/AAC/ALAC • AIFF • CAF",
                FontId::proportional(12.0),
                WAVE_CENTER,
            );
            self.drop_overlay(ui, wave_rect);
            return;
        };

        // --- Interaction ---------------------------------------------------------------------
        let mut view = self.view;
        let resp = ui.interact(wave_rect, ui.id().with("wave"), Sense::click_and_drag());
        let (pressed, down, ptr, mods, dt, scroll, zoom) = ui.input(|i| {
            (
                i.pointer.primary_pressed(),
                i.pointer.primary_down(),
                i.pointer.interact_pos().or(i.pointer.hover_pos()),
                i.modifiers,
                i.stable_dt.min(0.1) as f64,
                i.smooth_scroll_delta,
                i.zoom_delta(),
            )
        });
        let frame_at = |v: &View, x: f32| v.frame_at(wave_rect, x).round().clamp(0.0, len as f64) as usize;
        let near_edge = |v: &View, sel: Sel, x: f32| {
            !sel.is_empty()
                && ((v.x_of(wave_rect, sel.start as f64) - x).abs() <= 5.0 || (v.x_of(wave_rect, sel.end as f64) - x).abs() <= 5.0)
        };

        if let Some(ptr) = ptr {
            if pressed && resp.hovered() && len > 0 {
                let f = frame_at(&view, ptr.x);
                let sel = self.sel;
                let near = |frame: usize| (view.x_of(wave_rect, frame as f64) - ptr.x).abs() <= 5.0;
                let (anchor, moved) = if mods.shift {
                    (self.anchor, true)
                } else if !sel.is_empty() && near(sel.start) {
                    (sel.end, true)
                } else if !sel.is_empty() && near(sel.end) {
                    (sel.start, true)
                } else {
                    (f, false)
                };
                if moved {
                    self.sel = Sel::new(anchor, f);
                    self.paused_at = None;
                }
                self.anchor = anchor;
                self.drag = Some(Drag { anchor, press_x: ptr.x, moved });
            }
            if let Some(d) = &mut self.drag {
                if down {
                    if (ptr.x - d.press_x).abs() > 3.0 {
                        d.moved = true;
                    }
                    if d.moved {
                        // Auto-scroll when dragging past either edge.
                        let over = if ptr.x < wave_rect.left() {
                            ptr.x - wave_rect.left()
                        } else if ptr.x > wave_rect.right() {
                            ptr.x - wave_rect.right()
                        } else {
                            0.0
                        };
                        if over != 0.0 {
                            view.start += over as f64 * view.spp * dt * 12.0;
                            view.clamp(len, wave_rect.width());
                            ui.ctx().request_repaint();
                        }
                        let f = frame_at(&view, ptr.x.clamp(wave_rect.left(), wave_rect.right()));
                        self.sel = Sel::new(d.anchor, f);
                        self.paused_at = None;
                    }
                } else {
                    let d = self.drag.take().expect("checked above");
                    if !d.moved {
                        let f = frame_at(&view, d.press_x);
                        self.sel = Sel::cursor(f);
                        self.anchor = f;
                        self.paused_at = None;
                        if self.player.is_playing() {
                            self.player.retarget(f, len, 0);
                            self.play = Some(PlayInfo { had_selection: false });
                        }
                    }
                }
            }
        } else if !down {
            self.drag = None;
        }
        if resp.triple_clicked() {
            actions.push(Action::SelectAll);
        } else if resp.double_clicked() {
            actions.push(Action::SelectView);
        }

        // Hover readout and cursor shape.
        self.hover = None;
        if resp.hovered()
            && let Some(ptr) = ptr
        {
            let n_ch = self.doc.as_ref().map_or(1, Document::n_chans);
            let lanes = wave::lane_rects(wave_rect, n_ch);
            if let Some((ch, lane)) = lanes.iter().enumerate().find(|(_, l)| l.y_range().contains(ptr.y)) {
                let scale = (lane.height() / 2.0 - 1.0) * view.vzoom;
                self.hover = Some(Hover { frame: frame_at(&view, ptr.x), ch, amp: (lane.center().y - ptr.y) / scale });
            }
            let icon = if self.drag.as_ref().is_some_and(|d| d.moved) || near_edge(&view, self.sel, ptr.x) {
                CursorIcon::ResizeHorizontal
            } else {
                CursorIcon::Text
            };
            ui.ctx().set_cursor_icon(icon);
        }

        // Wheel zooms around the mouse, horizontal scroll pans, pinch zooms.
        let over_display = ptr.is_some_and(|p| wave_rect.union(tr_rect).union(ov_rect).contains(p)) && resp.hovered()
            || ptr.is_some_and(|p| tr_rect.union(ov_rect).contains(p));
        if over_display && len > 0 {
            let ptr = ptr.expect("checked above");
            let anchor = view.frame_at(wave_rect, ptr.x.clamp(wave_rect.left(), wave_rect.right()));
            if zoom != 1.0 {
                view.zoom_at(zoom as f64, anchor, wave_rect, len);
            }
            if scroll.y.abs() > scroll.x.abs() {
                view.zoom_at((scroll.y as f64 * 0.004).exp(), anchor, wave_rect, len);
            } else if scroll.x != 0.0 {
                view.start -= scroll.x as f64 * view.spp;
                view.clamp(len, wave_rect.width());
            }
        }

        // Clicking or dragging in the time ruler moves the cursor (or the playhead).
        let rresp = ui.interact(tr_rect, ui.id().with("ruler"), Sense::click_and_drag());
        if (rresp.clicked() || rresp.dragged())
            && let Some(p) = rresp.interact_pointer_pos()
        {
            let f = frame_at(&view, p.x);
            if self.player.is_playing() {
                self.player.retarget(f, len, 0);
                self.play = Some(PlayInfo { had_selection: false });
            } else {
                self.sel = Sel::cursor(f);
                self.anchor = f;
                self.paused_at = None;
            }
        }
        if rresp.hovered() {
            ui.ctx().set_cursor_icon(CursorIcon::PointingHand);
        }

        // Page-flip to follow the playhead.
        let playhead = self.playhead();
        if let Some(ph) = playhead
            && self.settings.follow
            && self.drag.is_none()
        {
            let vis = view.visible(wave_rect.width());
            if (ph as f64) < view.start || ph as f64 > view.start + vis {
                view.start = ph as f64 - vis * 0.02;
                view.clamp(len, wave_rect.width());
            }
        }

        // --- Painting ------------------------------------------------------------------------
        let doc = self.doc.as_ref().expect("checked above");
        let st = WaveState {
            doc,
            view,
            sel: self.sel.clamp(len),
            playhead,
            paused_at: self.paused_at,
            show_cursor: self.sel.is_empty(),
        };
        self.overview.show(ui, ov_rect, &st, &mut view, wave_rect.width());
        let st = WaveState { view, ..st };
        let ppp = ui.ctx().pixels_per_point();
        wave::paint_wave(&ui.painter_at(wave_rect), wave_rect, &st, &mut self.cols, ppp);
        if len == 0 {
            painter.text(wave_rect.center(), Align2::CENTER_CENTER, "Empty — paste audio here (⌘V)", FontId::proportional(15.0), WAVE_FG);
        }
        wave::paint_amp_ruler(&painter.with_clip_rect(amp_rect), amp_rect, doc.n_chans(), view.vzoom);
        wave::paint_time_ruler(&painter, tr_rect, wave_rect, view, doc.rate(), playhead);
        wave::scrollbar(ui, sb_rect, &mut view, len, wave_rect.width());
        self.view = view;

        let can = (!self.sel.is_empty(), self.clipboard.is_some(), len > 0);
        resp.context_menu(|ui| {
            item(ui, actions, "Cut", "⌘X", can.0, Action::Cut);
            item(ui, actions, "Copy", "⌘C", can.0, Action::Copy);
            item(ui, actions, "Paste", "⌘V", can.1, Action::Paste);
            item(ui, actions, "Delete", "⌫", can.0, Action::Delete);
            item(ui, actions, "Trim", "⌘T", can.0, Action::Trim);
            ui.separator();
            item(ui, actions, "Select Entire Wave", "⌘A", can.2, Action::SelectAll);
            item(ui, actions, "Zoom to Selection", "⌘E", can.0, Action::ZoomSel);
            item(ui, actions, "Zoom Full", "⌘0", can.2, Action::ZoomFull);
            ui.separator();
            item(ui, actions, "Save Selection As…", "", can.0, Action::SaveSelection);
        });

        self.drop_overlay(ui, wave_rect);
    }

    fn drop_overlay(&self, ui: &Ui, rect: Rect) {
        if ui.input(|i| !i.raw.hovered_files.is_empty()) {
            let p = ui.painter();
            p.rect_filled(rect, CornerRadius::ZERO, Color32::from_black_alpha(170));
            p.rect_stroke(rect.shrink(6.0), CornerRadius::ZERO, Stroke::new(2.0, CURSOR), egui::StrokeKind::Inside);
            p.text(rect.center(), Align2::CENTER_CENTER, "Drop to open", FontId::proportional(20.0), CURSOR);
        }
    }

    fn dialogs(&mut self, ctx: &egui::Context, actions: &mut Vec<Action>) {
        if let Some(mut db) = self.amplify_db {
            let mut close = false;
            let modal = egui::Modal::new(egui::Id::new("amplify")).frame(dialog_frame()).show(ctx, |ui| {
                ui.set_width(300.0);
                ui.label(egui::RichText::new("Amplify").strong().size(15.0).color(TEXT));
                ui.add_space(6.0);
                ui.label(if self.sel.is_empty() { "Applies to the entire wave." } else { "Applies to the selection." });
                ui.add_space(4.0);
                ui.add(egui::Slider::new(&mut db, -24.0..=24.0).step_by(0.5).suffix(" dB"));
                ui.add_space(10.0);
                ui.horizontal(|ui| {
                    if push_button(ui, "OK", true).clicked() || ui.input(|i| i.key_pressed(Key::Enter)) {
                        actions.push(Action::Effect(Effect::Amplify(db)));
                        close = true;
                    }
                    if push_button(ui, "Cancel", true).clicked() {
                        close = true;
                    }
                });
            });
            self.amplify_db = if close || modal.should_close() { None } else { Some(db) };
        }

        let mut show_about = self.show_about;
        egui::Window::new("About Kool Edit")
            .open(&mut show_about)
            .collapsible(false)
            .resizable(false)
            .anchor(Align2::CENTER_CENTER, vec2(0.0, 0.0))
            .frame(dialog_frame())
            .show(ctx, |ui| {
                ui.vertical_centered(|ui| {
                    let (r, _) = ui.allocate_exact_size(vec2(220.0, 46.0), Sense::hover());
                    ui.painter().rect_filled(r, CornerRadius::ZERO, LCD_BG);
                    let w = widgets::lcd_width("1.0", 30.0);
                    widgets::lcd(ui.painter(), pos2(r.center().x - w / 2.0, r.top() + 8.0), 30.0, "1.0", LCD_ON, LCD_OFF);
                    ui.add_space(6.0);
                    ui.label(egui::RichText::new("Kool Edit").strong().size(18.0).color(TEXT));
                    ui.label("A quick & dirty single-track audio editor and player,");
                    ui.label("in loving memory of Cool Edit 96/2000.");
                    ui.add_space(6.0);
                    ui.label(egui::RichText::new("Rust • egui • symphonia • cpal").small());
                });
            });
        self.show_about = show_about;

        let mut show_keys = self.show_keys;
        egui::Window::new("Keyboard Shortcuts")
            .open(&mut show_keys)
            .collapsible(false)
            .resizable(false)
            .frame(dialog_frame())
            .show(ctx, |ui| {
                egui::Grid::new("keys").striped(false).spacing(vec2(18.0, 3.0)).show(ui, |ui| {
                    for (k, what) in SHORTCUTS {
                        ui.label(egui::RichText::new(*k).monospace());
                        ui.label(*what);
                        ui.end_row();
                    }
                });
            });
        self.show_keys = show_keys;
    }
}

const SHORTCUTS: &[(&str, &str)] = &[
    ("Space", "Play / Stop"),
    ("P", "Pause / Resume"),
    ("L", "Toggle loop"),
    ("← →", "Move cursor (skip 5 s while playing)"),
    ("⇧← ⇧→", "Extend selection"),
    ("Home / End", "Go to beginning / end (⇧ extends)"),
    ("Click", "Set cursor (seeks while playing)"),
    ("Drag", "Select; drag selection edges to adjust"),
    ("⇧Click", "Extend selection"),
    ("Dbl / Triple-click", "Select visible / entire wave"),
    ("Wheel / Pinch", "Zoom around the mouse"),
    ("⇧Wheel / Swipe", "Scroll"),
    ("= / -", "Zoom in / out"),
    ("⌘0 / ⌘E", "Zoom full / to selection"),
    ("⌘X ⌘C ⌘V", "Cut / Copy / Paste"),
    ("⌫", "Delete selection"),
    ("⌘T", "Trim to selection"),
    ("⌘A / Esc", "Select all / deselect"),
    ("⌘Z / ⇧⌘Z", "Undo / Redo"),
    ("⌘O ⌘S ⇧⌘S", "Open / Save / Save As"),
];

fn dialog_frame() -> egui::Frame {
    egui::Frame::NONE
        .fill(FACE)
        .stroke(Stroke::new(1.0, DARK))
        .inner_margin(egui::Margin::same(14))
        .shadow(egui::Shadow { offset: [3, 3], blur: 0, spread: 0, color: Color32::from_black_alpha(90) })
}

fn item(ui: &mut Ui, actions: &mut Vec<Action>, label: &str, shortcut: &str, enabled: bool, action: Action) {
    let btn = egui::Button::new(label).shortcut_text(shortcut);
    if ui.add_enabled(enabled, btn).clicked() {
        actions.push(action);
        ui.close();
    }
}

fn separator(ui: &mut Ui) {
    let (r, _) = ui.allocate_exact_size(vec2(8.0, 22.0), Sense::hover());
    let x = r.center().x;
    ui.painter().vline(x, r.y_range().shrink(2.0), Stroke::new(1.0, SHADOW));
    ui.painter().vline(x + 1.0, r.y_range().shrink(2.0), Stroke::new(1.0, HILIGHT));
}

fn is_wav(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("wav") || e.eq_ignore_ascii_case("wave"))
}

fn new_source() -> SourceInfo {
    SourceInfo { codec: "PCM".to_owned(), bits: Some(16) }
}

impl eframe::App for KoolApp {
    #[cfg(feature = "devtools")]
    fn raw_input_hook(&mut self, ctx: &egui::Context, raw: &mut egui::RawInput) {
        use crate::devtools::{Command, save_png};
        for e in &raw.events {
            if let Event::Screenshot { image, .. } = e
                && let Some(path) = self.shot_path.take()
            {
                match save_png(&path, image) {
                    Ok(()) => eprintln!("devtools: saved {}", path.display()),
                    Err(e) => eprintln!("devtools: screenshot failed: {e}"),
                }
            }
        }
        let Some(script) = &mut self.script else { return };
        // Ignore the real mouse and keyboard so a human can't disturb the run.
        raw.events.retain(|e| matches!(e, Event::Screenshot { .. }));
        raw.hovered_files.clear();
        raw.dropped_files.clear();
        let cmd = script.feed(raw);
        let done = script.done();
        match cmd {
            Some(Command::Open(p)) => self.pending_open = Some(p),
            Some(Command::Shot(p)) => {
                self.shot_path = Some(p);
                ctx.send_viewport_cmd(ViewportCommand::Screenshot(Default::default()));
            }
            Some(Command::Quit) => {
                self.allow_close = true;
                self.stop_now();
                ctx.send_viewport_cmd(ViewportCommand::Close);
            }
            None => {}
        }
        if done && self.shot_path.is_none() {
            self.script = None;
        }
        ctx.request_repaint();
    }

    fn ui(&mut self, ui: &mut Ui, _frame: &mut eframe::Frame) {
        #[cfg(feature = "devtools")]
        let frame_start = Instant::now();
        let ctx = ui.ctx().clone();
        let mut actions = Vec::new();
        self.poll(&ctx, &mut actions);
        actions.extend(self.shortcuts(&ctx));

        let bar = |m: i8| egui::Frame::NONE.fill(FACE).inner_margin(egui::Margin::symmetric(m, 2));
        Panel::top("menu").frame(bar(4)).show_separator_line(false).show(ui, |ui| self.menu_bar(ui, &mut actions));
        Panel::top("toolbar").frame(bar(4)).show_separator_line(false).show(ui, |ui| {
            let r = ui.max_rect();
            ui.painter().hline(r.x_range(), r.top() - 1.0, Stroke::new(1.0, SHADOW));
            ui.painter().hline(r.x_range(), r.top(), Stroke::new(1.0, HILIGHT));
            self.toolbar(ui, &mut actions);
        });
        Panel::bottom("status").frame(bar(0)).exact_size(24.0).show_separator_line(false).show(ui, |ui| self.status_bar(ui));
        Panel::bottom("meters").frame(bar(0)).exact_size(38.0).show_separator_line(false).show(ui, |ui| self.meters(ui));
        Panel::bottom("controls").frame(bar(4)).show_separator_line(false).show(ui, |ui| self.controls(ui, &mut actions));
        egui::CentralPanel::default().frame(egui::Frame::NONE.fill(FACE)).show(ui, |ui| self.central(ui, &mut actions));
        self.dialogs(&ctx, &mut actions);

        for a in actions {
            self.run(a, &ctx);
        }
        self.update_title(&ctx);
        if self.settings != self.saved_settings {
            #[cfg(feature = "devtools")]
            let persist = self.script.is_none();
            #[cfg(not(feature = "devtools"))]
            let persist = true;
            if persist {
                self.settings.save();
            }
            self.saved_settings = self.settings.clone();
        }
        #[cfg(target_os = "macos")]
        crate::macos::set_dirty(self.doc.as_ref().is_some_and(Document::is_dirty));

        #[cfg(feature = "devtools")]
        if frame_start.elapsed().as_millis() > 25 {
            eprintln!("devtools: slow frame {} took {:?}", ctx.cumulative_frame_nr(), frame_start.elapsed());
        }

        let meters_moving = self.meter.db.iter().chain(&self.meter.hold).any(|&d| d > widgets::METER_FLOOR_DB);
        if self.player.is_playing() || self.loading.is_some() || meters_moving || self.default_rx.is_some() {
            ctx.request_repaint();
        }
    }
}
