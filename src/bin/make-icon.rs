//! Renders the app icon (a tiny Cool Edit window) into a macOS .iconset directory.
//! Usage: make-icon OUT.iconset   (then `iconutil -c icns OUT.iconset`)

use std::path::Path;

type Rgba = [f32; 4];

const FACE: Rgba = rgb(0xD4, 0xD0, 0xC8);
const WHITE: Rgba = rgb(0xFF, 0xFF, 0xFF);
const SHADOW: Rgba = rgb(0x80, 0x80, 0x80);
const DARK: Rgba = rgb(0x40, 0x40, 0x40);
const NAVY: Rgba = rgb(0x0A, 0x24, 0x6A);
const BLACK: Rgba = rgb(0, 0, 0);
const GREEN: Rgba = rgb(0x20, 0xE8, 0x40);
const SEL_BG: Rgba = rgb(0xF0, 0xF0, 0xF8);
const SEL_FG: Rgba = rgb(0x10, 0x28, 0x90);
const CLEAR: Rgba = [0.0; 4];

const fn rgb(r: u8, g: u8, b: u8) -> Rgba {
    [r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0, 1.0]
}

fn inside_rounded(x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) -> bool {
    if x < x0 || x > x1 || y < y0 || y > y1 {
        return false;
    }
    let cx = x.clamp(x0 + r, x1 - r);
    let cy = y.clamp(y0 + r, y1 - r);
    (x - cx).powi(2) + (y - cy).powi(2) <= r * r
}

fn in_rect(x: f32, y: f32, x0: f32, y0: f32, x1: f32, y1: f32) -> bool {
    x >= x0 && x < x1 && y >= y0 && y < y1
}

/// Waveform envelope at horizontal position t in 0..1: (min, max) in -1..1.
fn wave(t: f32) -> (f32, f32) {
    let beat = (t * 6.0).fract();
    let env = 0.25 + 0.65 * (-4.0 * beat).exp() * (0.6 + 0.4 * (t * 9.0).sin().abs());
    let wobble = 0.08 * (t * 70.0).sin();
    (-env + wobble * 0.5, env + wobble)
}

/// The icon in a 1024x1024 design space.
fn shade(x: f32, y: f32) -> Rgba {
    // Window body with a classic bevel.
    let (x0, y0, x1, y1, r) = (88.0, 88.0, 936.0, 936.0, 120.0);
    if !inside_rounded(x, y, x0, y0, x1, y1, r) {
        // Soft drop shadow.
        if inside_rounded(x - 14.0, y - 22.0, x0, y0, x1, y1, r) {
            return [0.0, 0.0, 0.0, 0.28];
        }
        return CLEAR;
    }
    let bevel = 22.0;
    if !inside_rounded(x, y, x0 + bevel, y0 + bevel, x1 - bevel, y1 - bevel, r - bevel) {
        // Light from the top-left.
        return if (x - x0) + (y - y0) < (x1 - x) + (y1 - y) { WHITE } else { DARK };
    }
    // Title bar.
    if in_rect(x, y, 130.0, 130.0, 894.0, 222.0) {
        let t = (x - 130.0) / 764.0;
        return [NAVY[0] + t * 0.35, NAVY[1] + t * 0.45, NAVY[2] + t * 0.6, 1.0];
    }
    // Sunken screen.
    let (sx0, sy0, sx1, sy1) = (150.0, 262.0, 874.0, 742.0);
    if in_rect(x, y, sx0 - 10.0, sy0 - 10.0, sx1 + 10.0, sy1 + 10.0) && !in_rect(x, y, sx0, sy0, sx1, sy1) {
        return if (x < sx0) || (y < sy0) { SHADOW } else { WHITE };
    }
    if in_rect(x, y, sx0, sy0, sx1, sy1) {
        let t = (x - sx0) / (sx1 - sx0);
        let selected = (0.38..0.66).contains(&t);
        let cy = (sy0 + sy1) / 2.0;
        let half = (sy1 - sy0) / 2.0 - 24.0;
        let (mn, mx) = wave(t);
        let on = y >= cy - mx * half && y <= cy - mn * half;
        if (x - (sx0 + 0.38 * (sx1 - sx0))).abs() < 5.0 && ((y - sy0) / 26.0) as i32 % 2 == 0 {
            return rgb(0xFF, 0xFF, 0x30);
        }
        return match (selected, on) {
            (true, true) => SEL_FG,
            (true, false) => SEL_BG,
            (false, true) => GREEN,
            (false, false) if (y - cy).abs() < 3.0 => rgb(0x00, 0x60, 0x18),
            _ => BLACK,
        };
    }
    // Transport buttons.
    for (i, bx) in [150.0f32, 290.0, 430.0].into_iter().enumerate() {
        let (b0, b1) = ((bx, 780.0), (bx + 120.0, 880.0));
        if in_rect(x, y, b0.0, b0.1, b1.0, b1.1) {
            if !in_rect(x, y, b0.0 + 8.0, b0.1 + 8.0, b1.0 - 8.0, b1.1 - 8.0) {
                return if (x - b0.0) < 8.0 || (y - b0.1) < 8.0 { WHITE } else { DARK };
            }
            let (cx, cy) = ((b0.0 + b1.0) / 2.0, (b0.1 + b1.1) / 2.0);
            let glyph = match i {
                0 => in_rect(x, y, cx - 24.0, cy - 24.0, cx + 24.0, cy + 24.0),
                1 => x > cx - 22.0 && (y - cy).abs() < (cx + 30.0 - x) * 0.62,
                _ => in_rect(x, y, cx - 26.0, cy - 26.0, cx - 8.0, cy + 26.0) || in_rect(x, y, cx + 8.0, cy - 26.0, cx + 26.0, cy + 26.0),
            };
            if glyph {
                return if i == 1 { rgb(0x00, 0x90, 0x10) } else { rgb(0x00, 0x00, 0x90) };
            }
            return FACE;
        }
    }
    // Green LCD.
    if in_rect(x, y, 600.0, 780.0, 874.0, 880.0) {
        let seg = in_rect(x, y, 630.0, 805.0, 844.0, 855.0) && ((x - 630.0) / 36.0) as i32 % 2 == 0 && ((y - 805.0) as i32 / 10) % 2 == 0;
        return if seg { rgb(0x30, 0xFF, 0x50) } else { BLACK };
    }
    FACE
}

fn render(size: u32) -> Vec<u8> {
    let ss = 4;
    let scale = 1024.0 / size as f32;
    let mut out = Vec::with_capacity((size * size * 4) as usize);
    for py in 0..size {
        for px in 0..size {
            let mut acc = [0.0f32; 4];
            for sy in 0..ss {
                for sx in 0..ss {
                    let x = (px as f32 + (sx as f32 + 0.5) / ss as f32) * scale;
                    let y = (py as f32 + (sy as f32 + 0.5) / ss as f32) * scale;
                    let c = shade(x, y);
                    // Accumulate premultiplied.
                    for (a, v) in acc.iter_mut().zip(c).take(3) {
                        *a += v * c[3];
                    }
                    acc[3] += c[3];
                }
            }
            let n = (ss * ss) as f32;
            let a = acc[3] / n;
            for premul in &acc[..3] {
                let v = if a > 0.0 { premul / n / a } else { 0.0 };
                out.push((v.clamp(0.0, 1.0) * 255.0).round() as u8);
            }
            out.push((a * 255.0).round() as u8);
        }
    }
    out
}

fn write_png(path: &Path, size: u32, data: &[u8]) {
    let file = std::fs::File::create(path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), size, size);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().expect("png header").write_image_data(data).expect("png data");
}

fn main() {
    let out = std::env::args().nth(1).expect("usage: make-icon OUT.iconset");
    let out = Path::new(&out);
    std::fs::create_dir_all(out).expect("create iconset dir");
    for base in [16u32, 32, 128, 256, 512] {
        for scale in [1u32, 2] {
            let px = base * scale;
            let name = if scale == 1 { format!("icon_{base}x{base}.png") } else { format!("icon_{base}x{base}@2x.png") };
            write_png(&out.join(name), px, &render(px));
        }
    }
}
