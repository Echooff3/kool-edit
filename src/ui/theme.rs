//! Late-90s Windows chrome around a black waveform display, Cool Edit style.

use std::sync::Arc;

use eframe::egui::{
    self, Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, Shadow, Stroke, TextStyle,
};

pub const FACE: Color32 = Color32::from_rgb(0xD4, 0xD0, 0xC8);
pub const HILIGHT: Color32 = Color32::WHITE;
pub const LIGHT: Color32 = Color32::from_rgb(0xE8, 0xE6, 0xE0);
pub const SHADOW: Color32 = Color32::from_rgb(0x80, 0x80, 0x80);
pub const DARK: Color32 = Color32::from_rgb(0x40, 0x40, 0x40);
pub const NAVY: Color32 = Color32::from_rgb(0x0A, 0x24, 0x6A);
pub const TEXT: Color32 = Color32::BLACK;
pub const DISABLED_TEXT: Color32 = Color32::from_rgb(0x80, 0x80, 0x80);

pub const WAVE_BG: Color32 = Color32::BLACK;
pub const WAVE_FG: Color32 = Color32::from_rgb(0x20, 0xE8, 0x40);
pub const WAVE_CENTER: Color32 = Color32::from_rgb(0x00, 0x60, 0x18);
pub const WAVE_GRID: Color32 = Color32::from_rgb(0x00, 0x2C, 0x0C);
pub const SEL_BG: Color32 = Color32::from_rgb(0xF0, 0xF0, 0xF8);
pub const SEL_FG: Color32 = Color32::from_rgb(0x10, 0x28, 0x90);
pub const SEL_CENTER: Color32 = Color32::from_rgb(0xA0, 0xA8, 0xD0);
pub const CURSOR: Color32 = Color32::from_rgb(0xFF, 0xFF, 0x30);
pub const PLAYHEAD: Color32 = Color32::from_rgb(0xFF, 0x40, 0x30);

pub const LCD_BG: Color32 = Color32::BLACK;
pub const LCD_ON: Color32 = Color32::from_rgb(0x30, 0xFF, 0x50);
pub const LCD_OFF: Color32 = Color32::from_rgb(0x06, 0x2A, 0x0C);

pub fn install(ctx: &egui::Context) {
    install_fonts(ctx);
    ctx.options_mut(|o| o.zoom_with_keyboard = false);
    // The look is the point, so ignore the system dark mode.
    ctx.set_theme(egui::Theme::Light);

    let mut style = (*ctx.global_style()).clone();
    style.text_styles = [
        (TextStyle::Small, FontId::proportional(10.5)),
        (TextStyle::Body, FontId::proportional(13.0)),
        (TextStyle::Button, FontId::proportional(13.0)),
        (TextStyle::Heading, FontId::proportional(17.0)),
        (TextStyle::Monospace, FontId::monospace(12.5)),
    ]
    .into();

    // Menus and tooltips snap open like they used to.
    style.animation_time = 0.0;

    let sp = &mut style.spacing;
    sp.item_spacing = egui::vec2(6.0, 3.0);
    sp.button_padding = egui::vec2(8.0, 2.0);
    sp.menu_margin = Margin::same(3);
    sp.window_margin = Margin::same(10);
    sp.interact_size.y = 20.0;
    sp.menu_width = 230.0;

    let v = &mut style.visuals;
    *v = egui::Visuals::light();
    v.panel_fill = FACE;
    v.window_fill = FACE;
    v.faint_bg_color = LIGHT;
    v.extreme_bg_color = Color32::WHITE;
    v.text_edit_bg_color = Some(Color32::WHITE);
    v.window_stroke = Stroke::new(1.0, DARK);
    v.window_corner_radius = CornerRadius::ZERO;
    v.menu_corner_radius = CornerRadius::ZERO;
    v.window_shadow = Shadow { offset: [3, 3], blur: 0, spread: 0, color: Color32::from_black_alpha(90) };
    v.popup_shadow = Shadow { offset: [2, 2], blur: 0, spread: 0, color: Color32::from_black_alpha(90) };
    v.selection.bg_fill = NAVY;
    v.selection.stroke = Stroke::new(1.0, Color32::WHITE);
    v.hyperlink_color = NAVY;

    let w = &mut v.widgets;
    for wv in [&mut w.noninteractive, &mut w.inactive, &mut w.hovered, &mut w.active, &mut w.open] {
        wv.corner_radius = CornerRadius::ZERO;
        wv.expansion = 0.0;
    }
    w.noninteractive.bg_fill = FACE;
    w.noninteractive.weak_bg_fill = FACE;
    w.noninteractive.bg_stroke = Stroke::new(1.0, SHADOW);
    w.noninteractive.fg_stroke = Stroke::new(1.0, TEXT);
    w.inactive.bg_fill = Color32::WHITE;
    w.inactive.weak_bg_fill = FACE;
    w.inactive.bg_stroke = Stroke::new(1.0, SHADOW);
    w.inactive.fg_stroke = Stroke::new(1.0, TEXT);
    // Menus highlight in navy with white text, like Windows 2000.
    w.hovered.bg_fill = NAVY;
    w.hovered.weak_bg_fill = NAVY;
    w.hovered.bg_stroke = Stroke::new(1.0, NAVY);
    w.hovered.fg_stroke = Stroke::new(1.0, Color32::WHITE);
    w.active.bg_fill = NAVY;
    w.active.weak_bg_fill = NAVY;
    w.active.bg_stroke = Stroke::new(1.0, NAVY);
    w.active.fg_stroke = Stroke::new(1.0, Color32::WHITE);
    w.open.bg_fill = NAVY;
    w.open.weak_bg_fill = NAVY;
    w.open.bg_stroke = Stroke::new(1.0, NAVY);
    w.open.fg_stroke = Stroke::new(1.0, Color32::WHITE);

    ctx.set_style_of(egui::Theme::Light, style.clone());
    ctx.set_style_of(egui::Theme::Dark, style);
}

fn install_fonts(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();
    // Tahoma ships with macOS and is the closest thing to the Win2000 UI font.
    for (name, path, family) in [
        ("tahoma", "/System/Library/Fonts/Supplemental/Tahoma.ttf", FontFamily::Proportional),
        ("couriernew", "/System/Library/Fonts/Supplemental/Courier New.ttf", FontFamily::Monospace),
    ] {
        if let Ok(bytes) = std::fs::read(path) {
            fonts.font_data.insert(name.to_owned(), Arc::new(FontData::from_owned(bytes)));
            fonts.families.entry(family).or_default().insert(0, name.to_owned());
        }
    }
    // Fallback for ⇧ ⌫ ⌥ and friends in menu shortcuts.
    if let Ok(bytes) = std::fs::read("/System/Library/Fonts/Apple Symbols.ttf") {
        fonts.font_data.insert("symbols".to_owned(), Arc::new(FontData::from_owned(bytes)));
        for family in [FontFamily::Proportional, FontFamily::Monospace] {
            fonts.families.entry(family).or_default().push("symbols".to_owned());
        }
    }
    ctx.set_fonts(fonts);
}
