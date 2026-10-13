//! A few remembered preferences, stored as `key=value` lines in
//! `~/Library/Application Support/Kool Edit/settings.txt` (or `~/.config/kool-edit` elsewhere).

use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    /// Start playing as soon as a file finishes loading.
    pub auto_play: bool,
    pub follow: bool,
    pub return_to_start: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { auto_play: true, follow: true, return_to_start: false }
    }
}

fn path() -> Option<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME")?);
    Some(if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Kool Edit/settings.txt")
    } else {
        home.join(".config/kool-edit/settings.txt")
    })
}

impl Settings {
    pub fn load() -> Self {
        let mut s = Settings::default();
        let Some(text) = path().and_then(|p| std::fs::read_to_string(p).ok()) else { return s };
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            let on = value.trim() == "true";
            match key.trim() {
                "auto_play" => s.auto_play = on,
                "follow" => s.follow = on,
                "return_to_start" => s.return_to_start = on,
                _ => {}
            }
        }
        s
    }

    pub fn save(&self) {
        let Some(path) = path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let text = format!(
            "auto_play={}\nfollow={}\nreturn_to_start={}\n",
            self.auto_play, self.follow, self.return_to_start
        );
        if let Err(e) = std::fs::write(&path, text) {
            eprintln!("kool-edit: couldn't save settings to {}: {e}", path.display());
        }
    }
}
