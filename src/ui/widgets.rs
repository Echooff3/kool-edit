//! Hand-painted classic widgets: 3D bevels, toolbar icons, the green LCD and level meters.

use eframe::egui::{
    self, Align2, Color32, CornerRadius, FontId, Painter, Pos2, Rect, Response, Sense, Shape, Stroke, StrokeKind,
    Ui, Vec2, pos2, vec2,
};

use super::theme::*;

/// Classic two-pixel Windows bevel.
pub fn bevel(p: &Painter, r: Rect, raised: bool) {
    let (outer_tl, outer_br, inner_tl, inner_br) =
        if raised { (HILIGHT, DARK, LIGHT, SHADOW) } else { (SHADOW, HILIGHT, DARK, LIGHT) };
    edge(p, r, outer_tl, outer_br);
    edge(p, r.shrink(1.0), inner_tl, inner_br);
}

/// One-pixel bevel (flat toolbar buttons, status fields).
pub fn thin_bevel(p: &Painter, r: Rect, raised: bool) {
    if raised { edge(p, r, HILIGHT, SHADOW) } else { edge(p, r, SHADOW, HILIGHT) }
}

fn edge(p: &Painter, r: Rect, tl: Color32, br: Color32) {
    let r = Rect::from_min_max(r.min + vec2(0.5, 0.5), r.max - vec2(0.5, 0.5));
    p.line_segment([r.left_bottom(), r.left_top()], Stroke::new(1.0, tl));
    p.line_segment([r.left_top(), r.right_top()], Stroke::new(1.0, tl));
    p.line_segment([r.right_top(), r.right_bottom()], Stroke::new(1.0, br));
    p.line_segment([r.right_bottom(), r.left_bottom() - vec2(0.5, 0.0)], Stroke::new(1.0, br));
}

/// Etched group box with a title, like the "Transport" and "Zoom" boxes in Cool Edit.
pub fn group_box<R>(ui: &mut Ui, title: &str, add: impl FnOnce(&mut Ui) -> R) -> R {
    let inner = egui::Frame::NONE
        .inner_margin(egui::Margin { left: 7, right: 7, top: 15, bottom: 6 })
        .show(ui, add);
    let r = inner.response.rect.shrink2(vec2(1.0, 0.0));
    let r = Rect::from_min_max(pos2(r.left(), r.top() + 7.0), r.max - vec2(0.0, 1.0));
    let p = ui.painter();
    p.rect_stroke(r.translate(vec2(1.0, 1.0)), CornerRadius::ZERO, Stroke::new(1.0, HILIGHT), StrokeKind::Inside);
    p.rect_stroke(r, CornerRadius::ZERO, Stroke::new(1.0, SHADOW), StrokeKind::Inside);
    let font = FontId::proportional(11.5);
    let galley = p.layout_no_wrap(title.to_owned(), font, TEXT);
    let tr = Rect::from_min_size(pos2(r.left() + 8.0, r.top() - galley.size().y / 2.0), galley.size() + vec2(6.0, 0.0));
    p.rect_filled(tr, CornerRadius::ZERO, FACE);
    p.galley(tr.min + vec2(3.0, 0.0), galley, TEXT);
    inner.inner
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Icon {
    New,
    Open,
    Save,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    Delete,
    Trim,
    Play,
    Stop,
    Pause,
    Loop,
    ToStart,
    ToEnd,
    Rewind,
    FastFwd,
    ZoomIn,
    ZoomOut,
    ZoomFull,
    ZoomSel,
    ZoomInV,
    ZoomOutV,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum BtnKind {
    /// Flat until hovered, like a Win2000 toolbar.
    Flat,
    /// Always raised, like the transport buttons.
    Raised,
}

pub fn icon_button(
    ui: &mut Ui,
    icon: Icon,
    size: Vec2,
    kind: BtnKind,
    enabled: bool,
    checked: bool,
    tip: &str,
) -> Response {
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let pressed = enabled && resp.is_pointer_button_down_on();
    let hovered = enabled && resp.hovered();
    let p = ui.painter();
    if checked && !pressed {
        p.rect_filled(rect.shrink(2.0), CornerRadius::ZERO, LIGHT);
    }
    let sunk = pressed || checked;
    match kind {
        BtnKind::Flat if sunk => thin_bevel(p, rect, false),
        BtnKind::Flat if hovered => thin_bevel(p, rect, true),
        BtnKind::Flat => {}
        BtnKind::Raised => bevel(p, rect, !sunk),
    }
    let side = (size.y - 8.0).clamp(12.0, 18.0);
    let off = if sunk { vec2(1.0, 1.0) } else { Vec2::ZERO };
    paint_icon(p, Rect::from_center_size(rect.center() + off, vec2(side, side)), icon, enabled);
    resp.on_hover_text(tip)
}

/// A raised push button with text, for dialogs.
pub fn push_button(ui: &mut Ui, text: &str, enabled: bool) -> Response {
    let font = FontId::proportional(13.0);
    let galley = ui.painter().layout_no_wrap(text.to_owned(), font, TEXT);
    let size = vec2((galley.size().x + 24.0).max(75.0), 23.0);
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let pressed = enabled && resp.is_pointer_button_down_on();
    let p = ui.painter();
    p.rect_filled(rect, CornerRadius::ZERO, FACE);
    bevel(p, rect, !pressed);
    let off = if pressed { vec2(1.0, 1.0) } else { Vec2::ZERO };
    let color = if enabled { TEXT } else { DISABLED_TEXT };
    p.galley_with_override_text_color(rect.center() - galley.size() / 2.0 + off, galley, color);
    resp
}

pub fn paint_icon(p: &Painter, r: Rect, icon: Icon, enabled: bool) {
    let c = |col: Color32| if enabled { col } else { grayed(col) };
    let pt = |x: f32, y: f32| pos2(r.left() + x * r.width(), r.top() + y * r.height());
    let rr = |x0: f32, y0: f32, x1: f32, y1: f32| Rect::from_min_max(pt(x0, y0), pt(x1, y1));
    let s = |w: f32, col: Color32| Stroke::new(w, c(col));
    let fill_poly = |pts: Vec<Pos2>, fill: Color32, outline: Color32| {
        let pts = if pts.len() == 3 { sorted_tri(pts) } else { pts };
        p.add(Shape::convex_polygon(pts, c(fill), Stroke::new(1.0, c(outline))));
    };
    let ink = Color32::from_rgb(0x10, 0x10, 0x10);
    let blue = Color32::from_rgb(0x00, 0x00, 0x90);
    let green = Color32::from_rgb(0x00, 0x90, 0x10);

    match icon {
        Icon::New => {
            fill_poly(
                vec![pt(0.2, 0.06), pt(0.6, 0.06), pt(0.82, 0.28), pt(0.82, 0.94), pt(0.2, 0.94)],
                Color32::WHITE,
                ink,
            );
            p.line_segment([pt(0.6, 0.06), pt(0.6, 0.28)], s(1.0, ink));
            p.line_segment([pt(0.6, 0.28), pt(0.82, 0.28)], s(1.0, ink));
        }
        Icon::Open => {
            let yellow = Color32::from_rgb(0xF0, 0xC8, 0x40);
            fill_poly(vec![pt(0.05, 0.22), pt(0.38, 0.22), pt(0.45, 0.32), pt(0.05, 0.32)], yellow, ink);
            p.rect_filled(rr(0.05, 0.32, 0.88, 0.86), CornerRadius::ZERO, c(yellow));
            p.rect_stroke(rr(0.05, 0.32, 0.88, 0.86), CornerRadius::ZERO, s(1.0, ink), StrokeKind::Inside);
            fill_poly(vec![pt(0.2, 0.5), pt(1.0, 0.5), pt(0.88, 0.86), pt(0.05, 0.86)], yellow.linear_multiply(0.85), ink);
        }
        Icon::Save => {
            p.rect_filled(rr(0.1, 0.08, 0.9, 0.92), CornerRadius::same(1), c(Color32::from_rgb(0x30, 0x30, 0x70)));
            p.rect_filled(rr(0.3, 0.08, 0.72, 0.38), CornerRadius::ZERO, c(Color32::from_rgb(0xC8, 0xC8, 0xD0)));
            p.rect_filled(rr(0.56, 0.13, 0.66, 0.33), CornerRadius::ZERO, c(Color32::from_rgb(0x30, 0x30, 0x70)));
            p.rect_filled(rr(0.22, 0.52, 0.78, 0.92), CornerRadius::ZERO, c(Color32::WHITE));
            for y in [0.64, 0.76] {
                p.line_segment([pt(0.3, y), pt(0.7, y)], s(1.0, Color32::from_rgb(0x90, 0x90, 0xB0)));
            }
        }
        Icon::Undo | Icon::Redo => {
            let flip = |x: f32| if icon == Icon::Undo { x } else { 1.0 - x };
            let pts: Vec<Pos2> = (0..=12)
                .map(|i| {
                    let a = std::f32::consts::PI * i as f32 / 12.0;
                    pt(flip(0.52 + 0.3 * a.cos()), 0.62 - 0.3 * a.sin())
                })
                .collect();
            p.add(Shape::line(pts, s(2.0, blue)));
            fill_poly(vec![pt(flip(0.06), 0.52), pt(flip(0.38), 0.52), pt(flip(0.22), 0.82)], blue, blue);
        }
        Icon::Cut => {
            p.line_segment([pt(0.36, 0.62), pt(0.7, 0.06)], s(1.6, ink));
            p.line_segment([pt(0.64, 0.62), pt(0.3, 0.06)], s(1.6, ink));
            for x in [0.28, 0.72] {
                p.circle_stroke(pt(x, 0.78), r.width() * 0.14, s(1.6, Color32::from_rgb(0x90, 0x10, 0x10)));
            }
        }
        Icon::Copy => {
            for (x, y) in [(0.08, 0.06), (0.4, 0.36)] {
                let pr = rr(x, y, x + 0.52, y + 0.58);
                p.rect_filled(pr, CornerRadius::ZERO, c(Color32::WHITE));
                p.rect_stroke(pr, CornerRadius::ZERO, s(1.0, ink), StrokeKind::Inside);
                for k in 1..4 {
                    let ly = y + 0.13 * k as f32;
                    p.line_segment([pt(x + 0.1, ly), pt(x + 0.42, ly)], s(1.0, SHADOW));
                }
            }
        }
        Icon::Paste => {
            let brown = Color32::from_rgb(0xB0, 0x78, 0x30);
            p.rect_filled(rr(0.1, 0.12, 0.7, 0.94), CornerRadius::same(1), c(brown));
            p.rect_filled(rr(0.26, 0.04, 0.54, 0.2), CornerRadius::ZERO, c(SHADOW));
            let paper = rr(0.42, 0.36, 0.92, 0.96);
            p.rect_filled(paper, CornerRadius::ZERO, c(Color32::WHITE));
            p.rect_stroke(paper, CornerRadius::ZERO, s(1.0, ink), StrokeKind::Inside);
            for k in 1..4 {
                let ly = 0.38 + 0.13 * k as f32;
                p.line_segment([pt(0.5, ly), pt(0.84, ly)], s(1.0, SHADOW));
            }
        }
        Icon::Delete => {
            let red = Color32::from_rgb(0xD0, 0x10, 0x10);
            p.line_segment([pt(0.15, 0.15), pt(0.85, 0.85)], s(3.0, red));
            p.line_segment([pt(0.85, 0.15), pt(0.15, 0.85)], s(3.0, red));
        }
        Icon::Trim => {
            // A crop mark: keep what's inside.
            p.add(Shape::line(vec![pt(0.28, 0.0), pt(0.28, 0.72), pt(1.0, 0.72)], s(2.0, ink)));
            p.add(Shape::line(vec![pt(0.0, 0.28), pt(0.72, 0.28), pt(0.72, 1.0)], s(2.0, ink)));
            let wave: Vec<Pos2> = (0..=8)
                .map(|i| pt(0.32 + 0.045 * i as f32, if i % 2 == 0 { 0.42 } else { 0.6 }))
                .collect();
            p.add(Shape::line(wave, s(1.2, green)));
        }
        Icon::Play => fill_poly(vec![pt(0.22, 0.1), pt(0.86, 0.5), pt(0.22, 0.9)], green, ink),
        Icon::Stop => {
            p.rect_filled(rr(0.16, 0.16, 0.84, 0.84), CornerRadius::ZERO, c(blue));
        }
        Icon::Pause => {
            p.rect_filled(rr(0.18, 0.14, 0.42, 0.86), CornerRadius::ZERO, c(blue));
            p.rect_filled(rr(0.58, 0.14, 0.82, 0.86), CornerRadius::ZERO, c(blue));
        }
        Icon::Loop => {
            p.add(Shape::line(
                vec![pt(0.7, 0.18), pt(0.9, 0.18), pt(0.9, 0.86), pt(0.1, 0.86), pt(0.1, 0.18), pt(0.42, 0.18)],
                s(1.6, blue),
            ));
            fill_poly(vec![pt(0.42, 0.02), pt(0.62, 0.18), pt(0.42, 0.34)], blue, blue);
            fill_poly(vec![pt(0.34, 0.36), pt(0.7, 0.56), pt(0.34, 0.76)], green, ink);
        }
        Icon::ToStart | Icon::ToEnd => {
            let f = |x: f32| if icon == Icon::ToStart { x } else { 1.0 - x };
            p.rect_filled(rr(f(0.14).min(f(0.28)), 0.15, f(0.14).max(f(0.28)), 0.85), CornerRadius::ZERO, c(blue));
            fill_poly(sorted_tri(vec![pt(f(0.3), 0.5), pt(f(0.86), 0.15), pt(f(0.86), 0.85)]), blue, blue);
        }
        Icon::Rewind | Icon::FastFwd => {
            let f = |x: f32| if icon == Icon::Rewind { x } else { 1.0 - x };
            for x0 in [0.08, 0.48] {
                fill_poly(sorted_tri(vec![pt(f(x0), 0.5), pt(f(x0 + 0.44), 0.15), pt(f(x0 + 0.44), 0.85)]), blue, blue);
            }
        }
        Icon::ZoomIn | Icon::ZoomOut | Icon::ZoomFull | Icon::ZoomSel | Icon::ZoomInV | Icon::ZoomOutV => {
            let vertical = matches!(icon, Icon::ZoomInV | Icon::ZoomOutV);
            let (cx, cy, rad) = if vertical { (0.55, 0.4, 0.28) } else { (0.42, 0.4, 0.3) };
            let center = pt(cx, cy);
            p.circle_filled(center, rad * r.width(), c(Color32::from_rgb(0xE0, 0xF0, 0xFF)));
            p.circle_stroke(center, rad * r.width(), s(1.5, ink));
            p.line_segment([pt(cx + rad * 0.72, cy + rad * 0.72), pt(cx + rad * 1.75, cy + rad * 1.75)], s(3.0, ink));
            let g = rad * 0.55;
            let glyph = s(1.6, ink);
            match icon {
                Icon::ZoomIn | Icon::ZoomInV => {
                    p.line_segment([pt(cx - g, cy), pt(cx + g, cy)], glyph);
                    p.line_segment([pt(cx, cy - g), pt(cx, cy + g)], glyph);
                }
                Icon::ZoomOut | Icon::ZoomOutV => {
                    p.line_segment([pt(cx - g, cy), pt(cx + g, cy)], glyph);
                }
                Icon::ZoomFull => {
                    p.line_segment([pt(cx - g, cy), pt(cx + g, cy)], glyph);
                    fill_poly(vec![pt(cx - g - 0.06, cy), pt(cx - g + 0.06, cy - 0.08), pt(cx - g + 0.06, cy + 0.08)], ink, ink);
                    fill_poly(vec![pt(cx + g + 0.06, cy), pt(cx + g - 0.06, cy + 0.08), pt(cx + g - 0.06, cy - 0.08)], ink, ink);
                }
                _ => {
                    // Selection brackets.
                    p.add(Shape::line(vec![pt(cx - g + 0.06, cy - g), pt(cx - g, cy - g), pt(cx - g, cy + g), pt(cx - g + 0.06, cy + g)], glyph));
                    p.add(Shape::line(vec![pt(cx + g - 0.06, cy - g), pt(cx + g, cy - g), pt(cx + g, cy + g), pt(cx + g - 0.06, cy + g)], glyph));
                }
            }
            if vertical {
                let red = Color32::from_rgb(0xB0, 0x10, 0x10);
                p.line_segment([pt(0.1, 0.12), pt(0.1, 0.88)], s(1.5, red));
                fill_poly(vec![pt(0.1, 0.02), pt(0.2, 0.18), pt(0.0, 0.18)], red, red);
                fill_poly(vec![pt(0.1, 0.98), pt(0.0, 0.82), pt(0.2, 0.82)], red, red);
            }
        }
    }
}

/// egui wants convex polygons in a consistent winding; mirrored icons flip it, so normalize.
fn sorted_tri(mut pts: Vec<Pos2>) -> Vec<Pos2> {
    let cross = (pts[1] - pts[0]).x * (pts[2] - pts[0]).y - (pts[1] - pts[0]).y * (pts[2] - pts[0]).x;
    if cross < 0.0 {
        pts.swap(1, 2);
    }
    pts
}

fn grayed(c: Color32) -> Color32 {
    let l = ((c.r() as u32 + c.g() as u32 + c.b() as u32) / 3) as u8;
    let l = 0x90u8.saturating_add(l / 4);
    Color32::from_rgba_unmultiplied(l, l, l, c.a())
}

// ---------------------------------------------------------------------------------------------
// Seven-segment LCD

const SEGMENTS: [u8; 10] = [
    0b0111111, // 0: a b c d e f
    0b0000110, // 1
    0b1011011, // 2
    0b1001111, // 3
    0b1100110, // 4
    0b1101101, // 5
    0b1111101, // 6
    0b0000111, // 7
    0b1111111, // 8
    0b1101111, // 9
];

fn char_advance(ch: char, h: f32) -> f32 {
    match ch {
        ':' | '.' => h * 0.32,
        _ => h * 0.62,
    }
}

pub fn lcd_width(text: &str, h: f32) -> f32 {
    text.chars().map(|c| char_advance(c, h)).sum()
}

/// Draw `text` (digits, ':' and '.') as glowing seven-segment digits with unlit ghosts behind them.
pub fn lcd(p: &Painter, origin: Pos2, h: f32, text: &str, on: Color32, off: Color32) {
    let mut x = origin.x;
    let t = (h * 0.11).max(2.0);
    let w = h * 0.5;
    let skew = 0.07;
    let top = origin.y;
    let k = |px: f32, py: f32| pos2(px + (top + h - py) * skew, py);
    for ch in text.chars() {
        match ch {
            ':' => {
                for fy in [0.3, 0.72] {
                    p.circle_filled(k(x + h * 0.12, top + h * fy), t * 0.6, on);
                }
            }
            '.' => {
                p.circle_filled(k(x + h * 0.1, top + h - t * 0.6), t * 0.6, on);
            }
            _ => {
                let mask = ch.to_digit(10).map_or(0, |d| SEGMENTS[d as usize]);
                let (x0, x1) = (x + t * 0.5, x + w - t * 0.5);
                let (y0, ym, y1) = (top + t * 0.5, top + h * 0.5, top + h - t * 0.5);
                let g = t * 0.18;
                let horiz = |y: f32| {
                    vec![
                        k(x0 + g, y),
                        k(x0 + g + t * 0.5, y - t * 0.5),
                        k(x1 - g - t * 0.5, y - t * 0.5),
                        k(x1 - g, y),
                        k(x1 - g - t * 0.5, y + t * 0.5),
                        k(x0 + g + t * 0.5, y + t * 0.5),
                    ]
                };
                let vert = |sx: f32, ya: f32, yb: f32| {
                    vec![
                        k(sx, ya + g),
                        k(sx + t * 0.5, ya + g + t * 0.5),
                        k(sx + t * 0.5, yb - g - t * 0.5),
                        k(sx, yb - g),
                        k(sx - t * 0.5, yb - g - t * 0.5),
                        k(sx - t * 0.5, ya + g + t * 0.5),
                    ]
                };
                let segs = [
                    horiz(y0),          // a
                    vert(x1, y0, ym),   // b
                    vert(x1, ym, y1),   // c
                    horiz(y1),          // d
                    vert(x0, ym, y1),   // e
                    vert(x0, y0, ym),   // f
                    horiz(ym),          // g
                ];
                for (i, seg) in segs.into_iter().enumerate() {
                    let lit = mask & (1 << i) != 0;
                    p.add(Shape::convex_polygon(seg, if lit { on } else { off }, Stroke::NONE));
                }
            }
        }
        x += char_advance(ch, h);
    }
}

// ---------------------------------------------------------------------------------------------
// Level meter

pub const METER_FLOOR_DB: f32 = -60.0;

pub fn to_db(lin: f32) -> f32 {
    if lin <= 1e-6 { -120.0 } else { 20.0 * lin.log10() }
}

/// Horizontal LED-style stereo meter with a dB scale underneath.
pub fn meter(p: &Painter, rect: Rect, db: [f32; 2], hold: [f32; 2], clipped: [bool; 2]) {
    p.rect_filled(rect, CornerRadius::ZERO, Color32::BLACK);
    let clip_w = 10.0;
    let scale_h = 12.0;
    let bars = Rect::from_min_max(rect.min + vec2(2.0, 2.0), pos2(rect.right() - clip_w - 4.0, rect.bottom() - scale_h - 1.0));
    let bar_h = (bars.height() - 2.0) / 2.0;
    let x_of = |d: f32| bars.left() + ((d - METER_FLOOR_DB) / -METER_FLOOR_DB).clamp(0.0, 1.0) * bars.width();
    let color_of = |d: f32| {
        if d >= -6.0 {
            Color32::from_rgb(0xFF, 0x30, 0x20)
        } else if d >= -18.0 {
            Color32::from_rgb(0xF0, 0xE0, 0x20)
        } else {
            Color32::from_rgb(0x20, 0xE0, 0x40)
        }
    };
    let seg = 4.0;
    for ch in 0..2 {
        let y0 = bars.top() + ch as f32 * (bar_h + 2.0);
        let mut x = bars.left();
        while x + seg - 1.0 <= bars.right() {
            let d = METER_FLOOR_DB + (x - bars.left() + seg / 2.0) / bars.width() * -METER_FLOOR_DB;
            let base = color_of(d);
            let col = if d <= db[ch] { base } else { base.linear_multiply(0.16) };
            p.rect_filled(Rect::from_min_size(pos2(x, y0), vec2(seg - 1.0, bar_h)), CornerRadius::ZERO, col);
            x += seg;
        }
        if hold[ch] > METER_FLOOR_DB {
            let hx = x_of(hold[ch]);
            p.rect_filled(Rect::from_min_size(pos2(hx - 1.0, y0), vec2(2.0, bar_h)), CornerRadius::ZERO, color_of(hold[ch]));
        }
        let clip = Rect::from_min_size(pos2(rect.right() - clip_w - 1.0, y0), vec2(clip_w - 1.0, bar_h));
        let red = Color32::from_rgb(0xFF, 0x20, 0x20);
        p.rect_filled(clip, CornerRadius::ZERO, if clipped[ch] { red } else { red.linear_multiply(0.18) });
    }
    // Scale.
    let font = FontId::proportional(9.5);
    let step = if bars.width() > 520.0 { 3 } else { 6 };
    for d in (METER_FLOOR_DB as i32..=0).step_by(step) {
        let x = x_of(d as f32);
        let y = rect.bottom() - scale_h;
        p.line_segment([pos2(x, y), pos2(x, y + 3.0)], Stroke::new(1.0, Color32::from_gray(150)));
        let label = if d == METER_FLOOR_DB as i32 { "dB".to_owned() } else { d.to_string() };
        let align = if d == 0 { Align2::RIGHT_TOP } else if d == METER_FLOOR_DB as i32 { Align2::LEFT_TOP } else { Align2::CENTER_TOP };
        p.text(pos2(x, y + 1.5), align, label, font.clone(), Color32::from_gray(200));
    }
}
