//! The waveform display: view math, cached min/max columns, rulers, overview and scrollbar.

use eframe::egui::{
    self, Align2, Color32, CornerRadius, FontId, Mesh, Painter, Rect, Sense, Shape, Stroke, Ui, pos2, vec2,
};

use super::theme::*;
use super::widgets::{bevel, thin_bevel};
use crate::doc::{Document, Sel};
use crate::timefmt;

/// Most zoomed-in: this many points per sample.
const MAX_PX_PER_SAMPLE: f64 = 64.0;

#[derive(Clone, Copy, Debug)]
pub struct View {
    /// First visible frame (fractional).
    pub start: f64,
    /// Frames per point.
    pub spp: f64,
    /// Vertical zoom; 1.0 shows full scale.
    pub vzoom: f32,
}

impl Default for View {
    fn default() -> Self {
        View { start: 0.0, spp: 1.0, vzoom: 1.0 }
    }
}

impl View {
    pub fn x_of(&self, rect: Rect, frame: f64) -> f32 {
        rect.left() + ((frame - self.start) / self.spp) as f32
    }

    pub fn frame_at(&self, rect: Rect, x: f32) -> f64 {
        self.start + (x - rect.left()) as f64 * self.spp
    }

    pub fn visible(&self, width: f32) -> f64 {
        width as f64 * self.spp
    }

    pub fn max_spp(len: usize, width: f32) -> f64 {
        (len as f64 / width.max(1.0) as f64).max(1.0 / MAX_PX_PER_SAMPLE)
    }

    pub fn clamp(&mut self, len: usize, width: f32) {
        self.spp = self.spp.clamp(1.0 / MAX_PX_PER_SAMPLE, Self::max_spp(len, width));
        let max_start = (len as f64 - self.visible(width)).max(0.0);
        self.start = self.start.clamp(0.0, max_start);
    }

    pub fn zoom_full(&mut self, len: usize, width: f32) {
        self.start = 0.0;
        self.spp = Self::max_spp(len, width);
    }

    /// Zoom by `factor` (>1 zooms in) keeping `anchor` frame under the same x.
    pub fn zoom_at(&mut self, factor: f64, anchor: f64, rect: Rect, len: usize) {
        let x = self.x_of(rect, anchor);
        self.spp /= factor;
        self.clamp(len, rect.width());
        self.start = anchor - (x - rect.left()) as f64 * self.spp;
        self.clamp(len, rect.width());
    }

    pub fn show_range(&mut self, a: usize, b: usize, len: usize, width: f32) {
        let span = (b.saturating_sub(a)).max(1) as f64;
        self.spp = span / width.max(1.0) as f64;
        self.start = a as f64;
        self.clamp(len, width);
    }

    /// Scroll just enough to bring `frame` into view.
    pub fn reveal(&mut self, frame: usize, len: usize, width: f32) {
        let f = frame as f64;
        let vis = self.visible(width);
        if f < self.start {
            self.start = f - vis * 0.1;
        } else if f > self.start + vis {
            self.start = f - vis * 0.9;
        }
        self.clamp(len, width);
    }
}

/// Per-channel (min, max) for each physical pixel column, recomputed only when the view or data changes.
#[derive(Default)]
pub struct ColumnCache {
    key: Option<(u64, u64, u64, usize)>,
    pub cols: Vec<Vec<Option<(f32, f32)>>>,
}

impl ColumnCache {
    fn update(&mut self, doc: &Document, start: f64, frames_per_col: f64, ncols: usize) {
        let key = (doc.version, start.to_bits(), frames_per_col.to_bits(), ncols);
        if self.key == Some(key) {
            return;
        }
        self.key = Some(key);
        let data = doc.read();
        self.cols = (0..data.n_chans())
            .map(|ch| {
                let mut prev: Option<(f32, f32)> = None;
                (0..ncols)
                    .map(|c| {
                        let f0 = start + c as f64 * frames_per_col;
                        let f1 = f0 + frames_per_col;
                        if f1 < 0.0 {
                            return None;
                        }
                        let a = f0.max(0.0).floor() as usize;
                        let b = (f1.ceil() as usize).max(a + 1);
                        let mut mm = doc.peaks.range_min_max(&data, ch, a..b)?;
                        // Join neighbouring columns so steep slopes don't leave gaps.
                        if let Some((pmin, pmax)) = prev {
                            if mm.0 > pmax {
                                mm.0 = pmax;
                            }
                            if mm.1 < pmin {
                                mm.1 = pmin;
                            }
                        }
                        prev = Some(mm);
                        Some(mm)
                    })
                    .collect()
            })
            .collect();
    }
}

pub struct WaveState<'a> {
    pub doc: &'a Document,
    pub view: View,
    pub sel: Sel,
    pub playhead: Option<usize>,
    pub paused_at: Option<usize>,
    pub show_cursor: bool,
}

pub fn lane_rects(rect: Rect, n: usize) -> Vec<Rect> {
    let n = n.max(1);
    let h = rect.height() / n as f32;
    (0..n)
        .map(|i| Rect::from_min_max(pos2(rect.left(), rect.top() + i as f32 * h), pos2(rect.right(), rect.top() + (i + 1) as f32 * h)))
        .collect()
}

pub fn paint_wave(p: &Painter, rect: Rect, st: &WaveState, cache: &mut ColumnCache, ppp: f32) {
    p.rect_filled(rect, CornerRadius::ZERO, WAVE_BG);
    let doc = st.doc;
    let view = st.view;
    let len = doc.len();
    let n_ch = doc.n_chans();
    let lanes = lane_rects(rect, n_ch);
    let px = 1.0 / ppp;

    let sel_x = (!st.sel.is_empty()).then(|| {
        let x0 = view.x_of(rect, st.sel.start as f64).max(rect.left());
        let x1 = view.x_of(rect, st.sel.end as f64).min(rect.right());
        (x0, (x1).max(x0 + px))
    });
    let in_sel = |x: f32| sel_x.is_some_and(|(a, b)| x >= a && x < b);

    for (ch, lane) in lanes.iter().enumerate() {
        let cy = lane.center().y;
        let scale = (lane.height() / 2.0 - 1.0) * view.vzoom;
        if let Some((x0, x1)) = sel_x {
            p.rect_filled(Rect::from_x_y_ranges(x0..=x1, lane.y_range()), CornerRadius::ZERO, SEL_BG);
        }
        // -6 dB guides and the centre line.
        for a in [0.5f32, -0.5] {
            let y = cy - a * scale;
            if y > lane.top() && y < lane.bottom() {
                p.hline(lane.x_range(), y, Stroke::new(px, WAVE_GRID));
            }
        }
        p.hline(lane.x_range(), cy, Stroke::new(px, WAVE_CENTER));
        if let Some((x0, x1)) = sel_x {
            p.hline(x0..=x1, cy, Stroke::new(px, SEL_CENTER));
        }

        let clamp_y = |y: f32| y.clamp(lane.top() + 1.0, lane.bottom() - 1.0);
        let frames_per_col = view.spp / ppp as f64;
        if frames_per_col >= 1.0 {
            let ncols = (rect.width() * ppp).ceil() as usize;
            cache.update(doc, view.start, frames_per_col, ncols);
            let mut mesh = Mesh::default();
            for (c, mm) in cache.cols.get(ch).into_iter().flatten().enumerate() {
                let Some((mn, mx)) = *mm else { continue };
                let x = rect.left() + c as f32 * px;
                let mut y0 = clamp_y(cy - mx * scale);
                let mut y1 = clamp_y(cy - mn * scale);
                if y1 - y0 < px {
                    let m = (y0 + y1) / 2.0;
                    y0 = m - px / 2.0;
                    y1 = m + px / 2.0;
                }
                let col = if in_sel(x) { SEL_FG } else { WAVE_FG };
                mesh.add_colored_rect(Rect::from_min_max(pos2(x, y0), pos2(x + px, y1)), col);
            }
            p.add(Shape::mesh(mesh));
        } else if len > 0 {
            // Zoomed in past one sample per pixel: connect the dots, and show the dots when there's room.
            let data = doc.read();
            let c = &data.chans[ch];
            let f0 = view.start.floor().max(0.0) as usize;
            let f1 = ((view.start + view.visible(rect.width())).ceil() as usize + 1).min(len - 1);
            let pts: Vec<_> = (f0.saturating_sub(1)..=f1)
                .map(|f| pos2(view.x_of(rect, f as f64), clamp_y(cy - c[f] * scale)))
                .collect();
            let wp = p.with_clip_rect(rect);
            for w in pts.windows(2) {
                let col = if in_sel((w[0].x + w[1].x) / 2.0) { SEL_FG } else { WAVE_FG };
                wp.line_segment([w[0], w[1]], Stroke::new(1.0, col));
            }
            if 1.0 / view.spp >= 6.0 {
                for q in &pts {
                    let col = if in_sel(q.x) { SEL_FG } else { WAVE_FG };
                    wp.rect_filled(Rect::from_center_size(*q, vec2(3.0, 3.0)), CornerRadius::ZERO, col);
                }
            }
        }
        if ch > 0 {
            p.hline(lane.x_range(), lane.top(), Stroke::new(1.0, Color32::from_gray(90)));
        }
    }

    // End-of-file marker when zoomed so the end is visible.
    let end_x = view.x_of(rect, len as f64);
    if end_x < rect.right() {
        p.rect_filled(Rect::from_min_max(pos2(end_x, rect.top()), rect.max), CornerRadius::ZERO, Color32::from_rgb(0x10, 0x10, 0x18));
    }

    let vline_at = |frame: usize| {
        let x = view.x_of(rect, frame as f64);
        (x >= rect.left() - 1.0 && x <= rect.right() + 1.0).then_some(x)
    };
    if st.show_cursor
        && let Some(x) = vline_at(st.sel.start)
    {
        let pts = [pos2(x, rect.top()), pos2(x, rect.bottom())];
        p.add(Shape::line_segment(pts, Stroke::new(1.0, Color32::from_rgb(0x50, 0x50, 0x00))));
        p.extend(Shape::dashed_line(&pts, Stroke::new(1.0, CURSOR), 4.0, 3.0));
    }
    if let Some(x) = st.paused_at.and_then(vline_at) {
        p.extend(Shape::dashed_line(&[pos2(x, rect.top()), pos2(x, rect.bottom())], Stroke::new(1.0, PLAYHEAD), 6.0, 3.0));
    }
    if let Some(x) = st.playhead.and_then(vline_at) {
        p.vline(x, rect.y_range(), Stroke::new(1.5, PLAYHEAD));
    }
}

/// Amplitude ruler to the right of the waveform, labelled in dB.
pub fn paint_amp_ruler(p: &Painter, rect: Rect, n_ch: usize, vzoom: f32) {
    p.rect_filled(rect, CornerRadius::ZERO, FACE);
    let font = FontId::proportional(10.0);
    let tick = Stroke::new(1.0, TEXT);
    let names = match n_ch {
        1 => vec!["M"],
        2 => vec!["L", "R"],
        n => (1..=n).map(|i| ["1", "2", "3", "4", "5", "6", "7", "8"].get(i - 1).copied().unwrap_or("·")).collect(),
    };
    for (ch, lane) in lane_rects(rect, n_ch).into_iter().enumerate() {
        let cy = lane.center().y;
        let scale = (lane.height() / 2.0 - 1.0) * vzoom;
        let mut last_y = f32::NEG_INFINITY;
        p.hline(rect.left()..=rect.left() + 6.0, cy, tick);
        p.text(pos2(rect.left() + 9.0, cy), Align2::LEFT_CENTER, "-∞", font.clone(), TEXT);
        for db in [0.0f32, -1.0, -2.0, -3.0, -4.0, -6.0, -9.0, -12.0, -18.0, -24.0, -30.0, -36.0, -48.0] {
            let a = 10f32.powf(db / 20.0);
            let dy = a * scale;
            if dy > lane.height() / 2.0 - 4.0 || (dy - last_y).abs() < 16.0 || dy < 14.0 {
                continue;
            }
            last_y = dy;
            for y in [cy - dy, cy + dy] {
                p.hline(rect.left()..=rect.left() + 4.0, y, tick);
                p.text(pos2(rect.left() + 9.0, y), Align2::LEFT_CENTER, format!("{db:.0}"), font.clone(), TEXT);
            }
        }
        if let Some(name) = names.get(ch) {
            p.text(pos2(rect.right() - 3.0, lane.top() + 2.0), Align2::RIGHT_TOP, *name, FontId::proportional(10.5), NAVY);
        }
        if ch > 0 {
            p.hline(rect.x_range(), lane.top(), Stroke::new(1.0, SHADOW));
        }
    }
}

/// Pick a "nice" tick interval in seconds for roughly `min_px` between labels.
fn tick_interval(secs_per_px: f64, min_px: f64) -> (f64, usize) {
    const STEPS: [(f64, usize); 25] = [
        (0.0001, 5), (0.0002, 4), (0.0005, 5), (0.001, 5), (0.002, 4), (0.005, 5), (0.01, 5), (0.02, 4),
        (0.05, 5), (0.1, 5), (0.2, 4), (0.5, 5), (1.0, 5), (2.0, 4), (5.0, 5), (10.0, 5), (15.0, 3),
        (30.0, 6), (60.0, 6), (120.0, 4), (300.0, 5), (600.0, 5), (900.0, 3), (1800.0, 6), (3600.0, 6),
    ];
    for (s, minor) in STEPS {
        if s / secs_per_px >= min_px {
            return (s, minor);
        }
    }
    (7200.0, 4)
}

/// Time ruler under the waveform; also marks the playhead.
pub fn paint_time_ruler(p: &Painter, rect: Rect, wave: Rect, view: View, rate: u32, playhead: Option<usize>) {
    p.rect_filled(rect, CornerRadius::ZERO, FACE);
    let rate = rate.max(1) as f64;
    let secs_per_px = view.spp / rate;
    let (major, minor_n) = tick_interval(secs_per_px, 78.0);
    let decimals = if major >= 1.0 { 0 } else if major >= 0.1 { 1 } else if major >= 0.01 { 2 } else if major >= 0.001 { 3 } else { 4 };
    let t0 = view.start / rate;
    let t1 = t0 + wave.width() as f64 * secs_per_px;
    let minor = major / minor_n as f64;
    let font = FontId::proportional(10.5);
    let mut k = (t0 / minor).floor() as i64;
    let p = p.with_clip_rect(rect);
    loop {
        let t = k as f64 * minor;
        if t > t1 + minor {
            break;
        }
        let x = wave.left() + ((t * rate - view.start) / view.spp) as f32;
        let is_major = k.rem_euclid(minor_n as i64) == 0;
        let h = if is_major { 6.0 } else { 3.0 };
        if t >= 0.0 {
            p.vline(x, rect.top()..=rect.top() + h, Stroke::new(1.0, TEXT));
            if is_major {
                // Keep edge labels fully on screen.
                let galley = p.layout_no_wrap(timefmt::format(t, decimals), font.clone(), TEXT);
                let half = galley.size().x / 2.0;
                let cx = x.clamp(rect.left() + half + 1.0, rect.right() - half - 1.0);
                p.galley(pos2(cx - half, rect.top() + 6.0), galley, TEXT);
            }
        }
        k += 1;
    }
    if let Some(ph) = playhead {
        let x = view.x_of(wave, ph as f64);
        if x >= wave.left() && x <= wave.right() {
            p.add(Shape::convex_polygon(
                vec![pos2(x - 4.0, rect.top()), pos2(x + 4.0, rect.top()), pos2(x, rect.top() + 6.0)],
                PLAYHEAD,
                Stroke::NONE,
            ));
        }
    }
}

/// Whole-file overview with the visible range boxed. Click or drag to move the view.
#[derive(Default)]
pub struct Overview {
    key: Option<(u64, usize)>,
    cols: Vec<Option<(f32, f32)>>,
}

impl Overview {
    pub fn show(&mut self, ui: &mut Ui, rect: Rect, st: &WaveState, view: &mut View, wave_width: f32) -> bool {
        let resp = ui.interact(rect, ui.id().with("overview"), Sense::click_and_drag());
        let p = ui.painter();
        bevel(p, rect, false);
        let inner = rect.shrink(2.0);
        p.rect_filled(inner, CornerRadius::ZERO, WAVE_BG);
        let doc = st.doc;
        let len = doc.len();
        if len == 0 {
            return false;
        }
        let ncols = inner.width().max(1.0) as usize;
        if self.key != Some((doc.version, ncols)) {
            self.key = Some((doc.version, ncols));
            let data = doc.read();
            let per = len as f64 / ncols as f64;
            self.cols = (0..ncols)
                .map(|c| {
                    let a = (c as f64 * per) as usize;
                    let b = (((c + 1) as f64 * per) as usize).max(a + 1);
                    (0..data.n_chans())
                        .filter_map(|ch| doc.peaks.range_min_max(&data, ch, a..b))
                        .reduce(|x, y| (x.0.min(y.0), x.1.max(y.1)))
                })
                .collect();
        }
        let x_of = |f: f64| inner.left() + (f / len as f64) as f32 * inner.width();
        if !st.sel.is_empty() {
            let r = Rect::from_x_y_ranges(x_of(st.sel.start as f64)..=x_of(st.sel.end as f64).max(x_of(st.sel.start as f64) + 1.0), inner.y_range());
            p.rect_filled(r, CornerRadius::ZERO, Color32::from_rgb(0x30, 0x38, 0x70));
        }
        let cy = inner.center().y;
        let h = inner.height() / 2.0 - 1.0;
        let mut mesh = Mesh::default();
        for (c, mm) in self.cols.iter().enumerate() {
            if let Some((mn, mx)) = mm {
                let x = inner.left() + c as f32;
                let (y0, y1) = (cy - mx.clamp(-1.0, 1.0) * h, cy - mn.clamp(-1.0, 1.0) * h);
                mesh.add_colored_rect(Rect::from_min_max(pos2(x, y0), pos2(x + 1.0, y1.max(y0 + 1.0))), Color32::from_rgb(0x18, 0xA8, 0x30));
            }
        }
        p.add(Shape::mesh(mesh));
        let vis = Rect::from_x_y_ranges(
            x_of(view.start)..=x_of(view.start + view.visible(wave_width)).max(x_of(view.start) + 3.0),
            inner.y_range(),
        );
        p.rect_filled(vis, CornerRadius::ZERO, Color32::from_white_alpha(28));
        p.rect_stroke(vis, CornerRadius::ZERO, Stroke::new(1.0, CURSOR), egui::StrokeKind::Inside);
        if let Some(ph) = st.playhead {
            p.vline(x_of(ph as f64), inner.y_range(), Stroke::new(1.0, PLAYHEAD));
        }
        if (resp.is_pointer_button_down_on() || resp.dragged())
            && let Some(pos) = resp.interact_pointer_pos()
        {
            let center = ((pos.x - inner.left()) / inner.width()).clamp(0.0, 1.0) as f64 * len as f64;
            view.start = center - view.visible(wave_width) / 2.0;
            view.clamp(len, wave_width);
            return true;
        }
        false
    }
}

/// Classic horizontal scrollbar with arrow buttons. Returns true if the view moved.
pub fn scrollbar(ui: &mut Ui, rect: Rect, view: &mut View, len: usize, wave_width: f32) -> bool {
    let p = ui.painter().clone();
    p.rect_filled(rect, CornerRadius::ZERO, LIGHT);
    let btn = rect.height();
    let left = Rect::from_min_size(rect.min, vec2(btn, btn));
    let right = Rect::from_min_size(pos2(rect.right() - btn, rect.top()), vec2(btn, btn));
    let track = Rect::from_min_max(pos2(left.right(), rect.top()), pos2(right.left(), rect.bottom()));
    let vis = view.visible(wave_width);
    let mut moved = false;
    let old_start = view.start;

    for (r, dir) in [(left, -1.0), (right, 1.0)] {
        let resp = ui.interact(r, ui.id().with(("sb_arrow", dir as i32)), Sense::click_and_drag());
        let down = resp.is_pointer_button_down_on();
        p.rect_filled(r, CornerRadius::ZERO, FACE);
        bevel(&p, r, !down);
        let c = r.center() + if down { vec2(1.0, 1.0) } else { vec2(0.0, 0.0) };
        let pts = if dir < 0.0 {
            vec![pos2(c.x - 2.5, c.y), pos2(c.x + 1.5, c.y - 4.0), pos2(c.x + 1.5, c.y + 4.0)]
        } else {
            vec![pos2(c.x + 2.5, c.y), pos2(c.x - 1.5, c.y + 4.0), pos2(c.x - 1.5, c.y - 4.0)]
        };
        p.add(Shape::convex_polygon(pts, TEXT, Stroke::NONE));
        if down {
            let dt = ui.input(|i| i.stable_dt) as f64;
            view.start += dir * vis * 0.6 * dt.min(0.1);
            ui.ctx().request_repaint();
        }
    }

    if len > 0 && track.width() > 8.0 {
        let frac_w = (vis / len as f64).min(1.0) as f32;
        let thumb_w = (track.width() * frac_w).max(14.0).min(track.width());
        let free = track.width() - thumb_w;
        let max_start = (len as f64 - vis).max(1.0);
        let thumb_x = track.left() + free * (view.start / max_start).clamp(0.0, 1.0) as f32;
        let thumb = Rect::from_min_size(pos2(thumb_x, track.top()), vec2(thumb_w, track.height()));

        let tresp = ui.interact(track, ui.id().with("sb_track"), Sense::click_and_drag());
        if tresp.drag_started() {
            let grab = tresp.interact_pointer_pos().map_or(0.0, |pp| pp.x - thumb.left());
            let grab = if (0.0..=thumb_w).contains(&grab) { grab } else { thumb_w / 2.0 };
            ui.memory_mut(|m| m.data.insert_temp(ui.id().with("sb_grab"), grab));
        }
        if tresp.dragged()
            && let Some(pp) = tresp.interact_pointer_pos()
        {
            let grab: f32 = ui.memory(|m| m.data.get_temp(ui.id().with("sb_grab")).unwrap_or(thumb_w / 2.0));
            let t = ((pp.x - grab - track.left()) / free.max(1.0)).clamp(0.0, 1.0) as f64;
            view.start = t * max_start;
        } else if tresp.clicked()
            && let Some(pp) = tresp.interact_pointer_pos()
        {
            // Page left/right like Windows.
            view.start += if pp.x < thumb.left() { -vis } else if pp.x > thumb.right() { vis } else { 0.0 };
        }
        p.rect_filled(thumb, CornerRadius::ZERO, FACE);
        bevel(&p, thumb, true);
        if thumb_w > 24.0 {
            for dx in [-3.0, 0.0, 3.0] {
                let x = thumb.center().x + dx;
                thin_bevel(&p, Rect::from_center_size(pos2(x, thumb.center().y), vec2(2.0, 7.0)), true);
            }
        }
    }
    view.clamp(len, wave_width);
    moved |= view.start != old_start;
    moved
}
