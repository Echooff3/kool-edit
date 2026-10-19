//! A few remembered preferences, stored as `key=value` lines in
//! `~/Library/Application Support/Kool Edit/settings.txt` (or `~/.config/kool-edit` elsewhere).

use std::path::PathBuf;

/// Bottom of the master-volume fader. Stored and shown as silence (−∞), not a tiny signal.
pub const VOLUME_MIN_DB: f32 = -60.0;
/// A little makeup gain above unity, matching a typical editor output fader.
pub const VOLUME_MAX_DB: f32 = 6.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    /// Start playing as soon as a file finishes loading.
    pub auto_play: bool,
    pub follow: bool,
    pub return_to_start: bool,
    /// Master output level in dB. `0.0` is unity. `VOLUME_MIN_DB` is silence.
    pub volume_db: f32,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { auto_play: true, follow: true, return_to_start: false, volume_db: 0.0 }
    }
}

/// Linear amplitude for a master-volume position. The floor is true silence.
pub fn volume_to_gain(db: f32) -> f32 {
    if !db.is_finite() || db <= VOLUME_MIN_DB {
        0.0
    } else {
        10f32.powf(db.min(VOLUME_MAX_DB) / 20.0)
    }
}

/// Quantize to 0.1 dB so the readout, the saved value, and the thumb agree.
pub fn snap_volume_db(db: f32) -> f32 {
    if !db.is_finite() {
        return 0.0;
    }
    let tenths = (db.clamp(VOLUME_MIN_DB, VOLUME_MAX_DB) * 10.0).round() as i32;
    let tenths = tenths.clamp((VOLUME_MIN_DB * 10.0) as i32, (VOLUME_MAX_DB * 10.0) as i32);
    tenths as f32 / 10.0
}

/// `−∞` at the floor, otherwise one decimal with a sign on boost (`0.0 dB`, `+6.0 dB`).
pub fn format_volume(db: f32) -> String {
    if !db.is_finite() || db <= VOLUME_MIN_DB {
        return "-∞".to_owned();
    }
    let tenths = (db.clamp(VOLUME_MIN_DB, VOLUME_MAX_DB) * 10.0).round() as i32;
    if tenths <= (VOLUME_MIN_DB * 10.0) as i32 {
        return "-∞".to_owned();
    }
    let (sign, abs) = if tenths > 0 { ("+", tenths) } else { ("-", tenths.abs()) };
    if tenths == 0 { "0.0 dB".to_owned() } else { format!("{sign}{}.{} dB", abs / 10, abs % 10) }
}

fn parse_volume_db(value: &str) -> Option<f32> {
    let db: f32 = value.trim().parse().ok()?;
    if db.is_finite() { Some(db.clamp(VOLUME_MIN_DB, VOLUME_MAX_DB)) } else { None }
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
        let Some(text) = path().and_then(|p| std::fs::read_to_string(p).ok()) else {
            return Settings::default();
        };
        Settings::from_text(&text)
    }

    fn from_text(text: &str) -> Self {
        let mut s = Settings::default();
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            let value = value.trim();
            let on = value == "true";
            match key.trim() {
                "auto_play" => s.auto_play = on,
                "follow" => s.follow = on,
                "return_to_start" => s.return_to_start = on,
                "volume_db" => {
                    if let Some(db) = parse_volume_db(value) {
                        s.volume_db = db;
                    }
                }
                _ => {}
            }
        }
        s
    }

    fn to_text(&self) -> String {
        format!(
            "auto_play={}\nfollow={}\nreturn_to_start={}\nvolume_db={}\n",
            self.auto_play, self.follow, self.return_to_start, self.volume_db
        )
    }

    pub fn save(&self) {
        let Some(path) = path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Err(e) = std::fs::write(&path, self.to_text()) {
            eprintln!("kool-edit: couldn't save settings to {}: {e}", path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_law_is_unity_at_zero_silence_at_the_floor_and_boosts() {
        assert_eq!(volume_to_gain(0.0), 1.0);
        assert_eq!(volume_to_gain(VOLUME_MIN_DB), 0.0);
        assert_eq!(volume_to_gain(-80.0), 0.0);
        assert_eq!(volume_to_gain(f32::NAN), 0.0);
        let plus6 = volume_to_gain(VOLUME_MAX_DB);
        assert!((plus6 - 1.9952623).abs() < 1e-4, "{plus6}");
        let minus6 = volume_to_gain(-6.0);
        assert!((minus6 - 0.5011872).abs() < 1e-4, "{minus6}");
        // Don't let a hand-edited file ask for more than the fader's top.
        assert_eq!(volume_to_gain(80.0), volume_to_gain(VOLUME_MAX_DB));
    }

    #[test]
    fn volume_readout_and_snap() {
        assert_eq!(format_volume(0.0), "0.0 dB");
        assert_eq!(format_volume(VOLUME_MIN_DB), "-∞");
        assert_eq!(format_volume(-80.0), "-∞");
        assert_eq!(format_volume(-12.5), "-12.5 dB");
        assert_eq!(format_volume(-0.9), "-0.9 dB");
        assert_eq!(format_volume(6.0), "+6.0 dB");
        assert_eq!(format_volume(0.5), "+0.5 dB");
        assert_eq!(snap_volume_db(0.04), 0.0);
        assert_eq!(snap_volume_db(100.0), VOLUME_MAX_DB);
        assert_eq!(snap_volume_db(-100.0), VOLUME_MIN_DB);
        assert_eq!(snap_volume_db(f32::NAN), 0.0);
        for tenths in -600..=60 {
            let db = snap_volume_db(tenths as f32 / 10.0);
            assert_eq!(snap_volume_db(db), db, "snap wasn't stable at {db}");
        }
    }

    #[test]
    fn settings_text_roundtrip_keeps_volume_and_old_files_stay_at_unity() {
        let mut s = Settings { auto_play: false, follow: true, return_to_start: true, volume_db: -12.5 };
        assert_eq!(Settings::from_text(&s.to_text()), s);
        s.volume_db = 0.0;
        let legacy = Settings::from_text("auto_play=false\nfollow=true\nreturn_to_start=true\n");
        assert_eq!(legacy, s);
        assert_eq!(Settings::from_text("volume_db=nope\nvolume_db=nan\n").volume_db, 0.0);
        assert_eq!(Settings::from_text("volume_db=80\n").volume_db, VOLUME_MAX_DB);
        assert_eq!(Settings::from_text("volume_db=-80\n").volume_db, VOLUME_MIN_DB);
    }
}
