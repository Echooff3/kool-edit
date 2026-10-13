//! `m:ss.ddd` style time formatting and parsing.

/// Format seconds as `m:ss.ddd` (or `h:mm:ss.ddd`) with `decimals` fractional digits.
pub fn format(secs: f64, decimals: usize) -> String {
    let secs = secs.max(0.0);
    let scale = 10f64.powi(decimals as i32);
    let total = (secs * scale).round() as u64;
    let scale = scale as u64;
    let frac = total % scale;
    let whole = total / scale;
    let (h, m, s) = (whole / 3600, (whole / 60) % 60, whole % 60);
    let mut out = if h > 0 { format!("{h}:{m:02}:{s:02}") } else { format!("{m}:{s:02}") };
    if decimals > 0 {
        out.push_str(&format!(".{frac:0decimals$}"));
    }
    out
}

/// Parse `ss.ddd`, `m:ss.ddd` or `h:mm:ss.ddd`.
pub fn parse(text: &str) -> Option<f64> {
    let parts: Vec<&str> = text.trim().split(':').collect();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }
    let mut secs = 0.0;
    for (i, p) in parts.iter().enumerate() {
        let v: f64 = p.trim().parse().ok()?;
        if v < 0.0 || (i < parts.len() - 1 && v.fract() != 0.0) {
            return None;
        }
        secs = secs * 60.0 + v;
    }
    Some(secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        assert_eq!(format(0.0, 3), "0:00.000");
        assert_eq!(format(83.2567, 3), "1:23.257");
        assert_eq!(format(3725.5, 1), "1:02:05.5");
        assert_eq!(format(59.9999, 3), "1:00.000");
        assert_eq!(format(12.0, 0), "0:12");
        assert_eq!(parse("1:23.257"), Some(83.257));
        assert_eq!(parse("83.5"), Some(83.5));
        assert_eq!(parse("1:02:05.5"), Some(3725.5));
        assert_eq!(parse("abc"), None);
        assert_eq!(parse("1.5:00"), None);
    }
}
