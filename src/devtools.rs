//! Scripted input and self-screenshots for testing the UI without a human
//! (`cargo run --features devtools` with `KOOL_SCRIPT` set).
//!
//! Steps are separated by `;`:
//! `wait N`, `move X Y`, `down`, `up`, `click X Y`, `drag X1 Y1 X2 Y2`, `key NAME [cmd] [shift]`,
//! `type TEXT`, `cut`, `copy`, `paste`, `scroll DX DY`, `open PATH`, `shot PATH`, `quit`.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use eframe::egui::{self, Event, Key, Modifiers, PointerButton, Pos2, RawInput, pos2, vec2};

enum Step {
    Wait(u32),
    Move(Pos2),
    Button(bool),
    Key(Key, Modifiers),
    Event(Event),
    Scroll(egui::Vec2),
    Open(PathBuf),
    Shot(PathBuf),
    Quit,
}

pub enum Command {
    Open(PathBuf),
    Shot(PathBuf),
    Quit,
}

pub struct Script {
    steps: VecDeque<Step>,
    wait: u32,
    pos: Pos2,
    mods: Modifiers,
    release_key: Option<(Key, Modifiers)>,
}

impl Script {
    pub fn from_env() -> Option<Self> {
        let text = std::env::var("KOOL_SCRIPT").ok()?;
        let mut steps = VecDeque::new();
        for raw in text.split(';').map(str::trim).filter(|s| !s.is_empty()) {
            let w: Vec<&str> = raw.split_whitespace().collect();
            let num = |i: usize| w.get(i).and_then(|s| s.parse::<f32>().ok()).unwrap_or(0.0);
            match w[0] {
                "wait" => steps.push_back(Step::Wait(num(1) as u32)),
                "move" => steps.push_back(Step::Move(pos2(num(1), num(2)))),
                "down" => steps.push_back(Step::Button(true)),
                "up" => steps.push_back(Step::Button(false)),
                "click" => {
                    steps.push_back(Step::Move(pos2(num(1), num(2))));
                    steps.push_back(Step::Button(true));
                    steps.push_back(Step::Button(false));
                }
                "drag" => {
                    let (a, b) = (pos2(num(1), num(2)), pos2(num(3), num(4)));
                    steps.push_back(Step::Move(a));
                    steps.push_back(Step::Button(true));
                    for i in 1..=8 {
                        steps.push_back(Step::Move(a.lerp(b, i as f32 / 8.0)));
                    }
                    steps.push_back(Step::Button(false));
                }
                "key" => {
                    let key = Key::from_name(w.get(1).copied().unwrap_or("")).unwrap_or_else(|| panic!("unknown key in {raw:?}"));
                    let mut m = Modifiers::NONE;
                    for f in &w[2..] {
                        match *f {
                            "cmd" => m |= Modifiers::COMMAND,
                            "shift" => m |= Modifiers::SHIFT,
                            "alt" => m |= Modifiers::ALT,
                            _ => {}
                        }
                    }
                    steps.push_back(Step::Key(key, m));
                }
                "type" => steps.push_back(Step::Event(Event::Text(raw[5..].to_owned()))),
                "cut" => steps.push_back(Step::Event(Event::Cut)),
                "copy" => steps.push_back(Step::Event(Event::Copy)),
                "paste" => steps.push_back(Step::Event(Event::Paste(String::new()))),
                "scroll" => steps.push_back(Step::Scroll(vec2(num(1), num(2)))),
                "open" => steps.push_back(Step::Open(PathBuf::from(w[1..].join(" ")))),
                "shot" => steps.push_back(Step::Shot(PathBuf::from(w[1..].join(" ")))),
                "quit" => steps.push_back(Step::Quit),
                other => panic!("unknown script step {other:?}"),
            }
        }
        Some(Script { steps, wait: 10, pos: pos2(0.0, 0.0), mods: Modifiers::NONE, release_key: None })
    }

    /// Inject at most one step's worth of input per frame.
    pub fn feed(&mut self, raw: &mut RawInput) -> Option<Command> {
        if let Some((key, modifiers)) = self.release_key.take() {
            raw.events.push(Event::Key { key, physical_key: None, pressed: false, repeat: false, modifiers });
            raw.events.push(Event::ModifiersChanged(self.mods));
            return None;
        }
        if self.wait > 0 {
            self.wait -= 1;
            return None;
        }
        match self.steps.pop_front()? {
            Step::Wait(n) => self.wait = n,
            Step::Move(p) => {
                self.pos = p;
                raw.events.push(Event::PointerMoved(p));
            }
            Step::Button(pressed) => raw.events.push(Event::PointerButton {
                pos: self.pos,
                button: PointerButton::Primary,
                pressed,
                modifiers: self.mods,
            }),
            Step::Key(key, modifiers) => {
                raw.events.push(Event::ModifiersChanged(modifiers));
                raw.events.push(Event::Key { key, physical_key: None, pressed: true, repeat: false, modifiers });
                self.release_key = Some((key, modifiers));
            }
            Step::Event(e) => raw.events.push(e),
            Step::Scroll(delta) => raw.events.push(Event::MouseWheel {
                unit: egui::MouseWheelUnit::Point,
                delta,
                phase: egui::TouchPhase::Move,
                modifiers: self.mods,
            }),
            Step::Open(p) => return Some(Command::Open(p)),
            Step::Shot(p) => {
                self.wait = 6;
                return Some(Command::Shot(p));
            }
            Step::Quit => return Some(Command::Quit),
        }
        None
    }

    pub fn done(&self) -> bool {
        self.steps.is_empty()
    }
}

pub fn save_png(path: &Path, image: &egui::ColorImage) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), image.size[0] as u32, image.size[1] as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(|e| e.to_string())?;
    let bytes: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_array()).collect();
    w.write_image_data(&bytes).map_err(|e| e.to_string())
}
