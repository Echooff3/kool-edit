//! The open file: its samples, selection-aware edit operations, and undo/redo.

use std::ops::Range;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::audio::{Effect, Peaks, Samples};
use crate::wav::WavFormat;

/// A selection in frames. `start == end` means "just a cursor".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Sel {
    pub start: usize,
    pub end: usize,
}

impl Sel {
    pub fn new(a: usize, b: usize) -> Self {
        Sel { start: a.min(b), end: a.max(b) }
    }

    pub fn cursor(at: usize) -> Self {
        Sel { start: at, end: at }
    }

    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }

    pub fn len(&self) -> usize {
        self.end - self.start
    }

    pub fn range(&self) -> Range<usize> {
        self.start..self.end
    }

    pub fn clamp(self, len: usize) -> Self {
        Sel { start: self.start.min(len), end: self.end.min(len) }
    }
}

/// What the file looked like on disk, for the status bar and default save format.
#[derive(Clone, Debug, Default)]
pub struct SourceInfo {
    pub codec: String,
    pub bits: Option<u32>,
}

/// One contiguous replacement, with enough data to undo and redo it.
struct Splice {
    start: usize,
    old: Vec<Vec<f32>>,
    new: Vec<Vec<f32>>,
}

struct Edit {
    id: u64,
    name: String,
    splices: Vec<Splice>,
    sel_before: Sel,
    sel_after: Sel,
}

const MAX_UNDO: usize = 100;

/// Unique across all documents, so view caches never mistake a new file for an old one.
fn next_version() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

pub struct Document {
    /// Shared with the audio thread for playback.
    pub data: Arc<RwLock<Samples>>,
    pub path: Option<PathBuf>,
    pub source: SourceInfo,
    pub wav_format: WavFormat,
    pub peaks: Peaks,
    /// Changes on every edit (and differs between documents) so view caches know to recompute.
    pub version: u64,
    undo: Vec<Edit>,
    redo: Vec<Edit>,
    next_id: u64,
    saved_id: u64,
}

impl Document {
    pub fn new(samples: Samples, path: Option<PathBuf>, source: SourceInfo) -> Self {
        let wav_format = WavFormat::for_source(&source);
        let peaks = Peaks::build(&samples);
        Document {
            data: Arc::new(RwLock::new(samples)),
            path,
            source,
            wav_format,
            peaks,
            version: next_version(),
            undo: Vec::new(),
            redo: Vec::new(),
            next_id: 1,
            saved_id: 0,
        }
    }

    pub fn read(&self) -> RwLockReadGuard<'_, Samples> {
        self.data.read().unwrap_or_else(|e| e.into_inner())
    }

    fn write(&self) -> RwLockWriteGuard<'_, Samples> {
        self.data.write().unwrap_or_else(|e| e.into_inner())
    }

    pub fn len(&self) -> usize {
        self.read().len()
    }

    pub fn rate(&self) -> u32 {
        self.read().rate
    }

    pub fn n_chans(&self) -> usize {
        self.read().n_chans()
    }

    pub fn display_name(&self) -> String {
        self.path
            .as_ref()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Untitled".to_owned())
    }

    fn current_id(&self) -> u64 {
        self.undo.last().map_or(0, |e| e.id)
    }

    pub fn is_dirty(&self) -> bool {
        self.current_id() != self.saved_id
    }

    pub fn mark_saved(&mut self) {
        self.saved_id = self.current_id();
    }

    pub fn undo_name(&self) -> Option<&str> {
        self.undo.last().map(|e| e.name.as_str())
    }

    pub fn redo_name(&self) -> Option<&str> {
        self.redo.last().map(|e| e.name.as_str())
    }

    pub fn copy(&self, sel: Sel) -> Option<Samples> {
        (!sel.is_empty()).then(|| self.read().extract(sel.range()))
    }

    /// Run a list of (range, replacement) splices in order as one undoable step.
    fn apply(&mut self, name: &str, ops: Vec<(Range<usize>, Vec<Vec<f32>>)>, sel_before: Sel, sel_after: Sel) -> Sel {
        let mut splices = Vec::with_capacity(ops.len());
        let mut lowest = usize::MAX;
        {
            let mut data = self.write();
            for (range, new) in ops {
                let range = data.clamp(range);
                lowest = lowest.min(range.start);
                let old = data.splice(range.clone(), &new);
                splices.push(Splice { start: range.start, old, new });
            }
        }
        self.after_change(lowest);
        self.redo.clear();
        self.undo.push(Edit { id: self.next_id, name: name.to_owned(), splices, sel_before, sel_after });
        self.next_id += 1;
        if self.undo.len() > MAX_UNDO {
            self.undo.remove(0);
            // The saved state may have just scrolled off the bottom of the stack; that's fine,
            // it can only be reached again by redo, which we just cleared.
        }
        sel_after
    }

    fn after_change(&mut self, from_frame: usize) {
        let data = self.data.read().unwrap_or_else(|e| e.into_inner());
        self.peaks.update_from(&data, from_frame);
        drop(data);
        self.version = next_version();
    }

    pub fn undo(&mut self) -> Option<Sel> {
        let edit = self.undo.pop()?;
        let mut lowest = usize::MAX;
        {
            let mut data = self.write();
            for s in edit.splices.iter().rev() {
                data.splice(s.start..s.start + s.new.first().map_or(0, Vec::len), &s.old);
                lowest = lowest.min(s.start);
            }
        }
        self.after_change(lowest);
        let sel = edit.sel_before;
        self.redo.push(edit);
        Some(sel)
    }

    pub fn redo(&mut self) -> Option<Sel> {
        let edit = self.redo.pop()?;
        let mut lowest = usize::MAX;
        {
            let mut data = self.write();
            for s in &edit.splices {
                data.splice(s.start..s.start + s.old.first().map_or(0, Vec::len), &s.new);
                lowest = lowest.min(s.start);
            }
        }
        self.after_change(lowest);
        let sel = edit.sel_after;
        self.undo.push(edit);
        Some(sel)
    }

    fn empty_insert(&self) -> Vec<Vec<f32>> {
        vec![Vec::new(); self.n_chans()]
    }

    pub fn delete(&mut self, sel: Sel) -> Option<Sel> {
        if sel.is_empty() {
            return None;
        }
        let ins = self.empty_insert();
        Some(self.apply("Delete", vec![(sel.range(), ins)], sel, Sel::cursor(sel.start)))
    }

    pub fn cut(&mut self, sel: Sel) -> Option<(Samples, Sel)> {
        let clip = self.copy(sel)?;
        let ins = self.empty_insert();
        let after = self.apply("Cut", vec![(sel.range(), ins)], sel, Sel::cursor(sel.start));
        Some((clip, after))
    }

    /// Insert at the cursor, or replace the selection. Leaves the cursor after the pasted audio.
    pub fn paste(&mut self, sel: Sel, clip: &Samples) -> Option<Sel> {
        if clip.is_empty() {
            return None;
        }
        if self.len() == 0 {
            // An empty document takes on the clipboard's format.
            let mut data = self.write();
            data.rate = clip.rate;
            data.chans = vec![Vec::new(); clip.n_chans()];
        }
        let new = clip.conform(self.rate(), self.n_chans());
        let n = new[0].len();
        Some(self.apply("Paste", vec![(sel.range(), new)], sel, Sel::cursor(sel.start + n)))
    }

    /// Keep only the selection.
    pub fn trim(&mut self, sel: Sel) -> Option<Sel> {
        let len = self.len();
        if sel.is_empty() || (sel.start == 0 && sel.end >= len) {
            return None;
        }
        let ops = vec![(sel.end..len, self.empty_insert()), (0..sel.start, self.empty_insert())];
        Some(self.apply("Trim", ops, sel, Sel::new(0, sel.len())))
    }

    /// Apply an effect to the selection, or the whole file if nothing is selected.
    pub fn effect(&mut self, sel: Sel, fx: Effect) -> Option<Sel> {
        let target = if sel.is_empty() { Sel::new(0, self.len()) } else { sel };
        if target.is_empty() {
            return None;
        }
        let mut chans = self.read().extract(target.range()).chans;
        fx.apply(&mut chans);
        Some(self.apply(fx.name(), vec![(target.range(), chans)], sel, target))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(n: usize) -> Document {
        let s = Samples { rate: 1000, chans: vec![(0..n).map(|i| i as f32).collect(), vec![0.5; n]] };
        Document::new(s, None, SourceInfo::default())
    }

    fn ch0(d: &Document) -> Vec<f32> {
        d.read().chans[0].clone()
    }

    #[test]
    fn cut_paste_undo_redo_roundtrip() {
        let mut d = doc(10);
        let original = ch0(&d);
        let (clip, sel) = d.cut(Sel::new(2, 5)).unwrap();
        assert_eq!(clip.chans[0], vec![2.0, 3.0, 4.0]);
        assert_eq!(sel, Sel::cursor(2));
        assert_eq!(d.len(), 7);
        assert!(d.is_dirty());

        let sel = d.paste(Sel::cursor(7), &clip).unwrap();
        assert_eq!(sel, Sel::cursor(10));
        assert_eq!(ch0(&d), vec![0.0, 1.0, 5.0, 6.0, 7.0, 8.0, 9.0, 2.0, 3.0, 4.0]);

        assert_eq!(d.undo(), Some(Sel::cursor(7)));
        assert_eq!(d.undo(), Some(Sel::new(2, 5)));
        assert_eq!(ch0(&d), original);
        assert!(!d.is_dirty());
        d.redo();
        d.redo();
        assert_eq!(ch0(&d), vec![0.0, 1.0, 5.0, 6.0, 7.0, 8.0, 9.0, 2.0, 3.0, 4.0]);
        assert!(d.undo_name() == Some("Paste"));
    }

    #[test]
    fn paste_replaces_selection() {
        let mut d = doc(6);
        let clip = d.copy(Sel::new(0, 1)).unwrap();
        d.paste(Sel::new(1, 4), &clip).unwrap();
        assert_eq!(ch0(&d), vec![0.0, 0.0, 4.0, 5.0]);
    }

    #[test]
    fn trim_keeps_selection_and_undoes() {
        let mut d = doc(10);
        let sel = d.trim(Sel::new(3, 6)).unwrap();
        assert_eq!(sel, Sel::new(0, 3));
        assert_eq!(ch0(&d), vec![3.0, 4.0, 5.0]);
        assert_eq!(d.read().chans[1].len(), 3);
        d.undo();
        assert_eq!(ch0(&d), (0..10).map(|i| i as f32).collect::<Vec<_>>());
    }

    #[test]
    fn delete_and_effects() {
        let mut d = doc(5);
        assert!(d.delete(Sel::cursor(2)).is_none());
        d.delete(Sel::new(0, 2)).unwrap();
        assert_eq!(ch0(&d), vec![2.0, 3.0, 4.0]);
        d.effect(Sel::default(), Effect::Silence).unwrap();
        assert_eq!(ch0(&d), vec![0.0; 3]);
        d.undo();
        assert_eq!(ch0(&d), vec![2.0, 3.0, 4.0]);
    }

    #[test]
    fn paste_into_empty_adopts_format() {
        let mut d = Document::new(Samples::silent(44100, 2), None, SourceInfo::default());
        let clip = Samples { rate: 8000, chans: vec![vec![0.1, 0.2, 0.3]] };
        d.paste(Sel::default(), &clip).unwrap();
        assert_eq!(d.rate(), 8000);
        assert_eq!(d.n_chans(), 1);
        assert_eq!(d.len(), 3);
    }

    #[test]
    fn new_edit_clears_redo() {
        let mut d = doc(5);
        d.delete(Sel::new(0, 1));
        d.undo();
        assert!(d.redo_name().is_some());
        d.delete(Sel::new(0, 2));
        assert!(d.redo_name().is_none());
    }
}
