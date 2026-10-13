//! Kool Edit: a quick and dirty single-track audio editor/player in the spirit of Cool Edit.

mod app;
mod audio;
mod decode;
#[cfg(feature = "devtools")]
mod devtools;
mod doc;
#[cfg(target_os = "macos")]
mod macos;
mod player;
mod settings;
mod timefmt;
mod ui;
mod wav;

use std::path::PathBuf;

use eframe::egui;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!(
            "Usage: kool-edit [FILE]\n       kool-edit --info FILE...    print what the decoder sees\n       kool-edit --make-default    (from the installed .app)"
        );
        return Ok(());
    }
    if args.first().is_some_and(|a| a == "--info") {
        let mut failed = false;
        for path in &args[1..] {
            let started = std::time::Instant::now();
            match decode::load(path.as_ref(), &Default::default()) {
                Ok(l) => println!(
                    "{path}: {} {} Hz, {} ch, {} bits, {} frames ({}), decoded in {:.2}s",
                    l.info.codec,
                    l.samples.rate,
                    l.samples.n_chans(),
                    l.info.bits.map_or("-".to_owned(), |b| b.to_string()),
                    l.samples.len(),
                    timefmt::format(l.samples.secs(l.samples.len()), 3),
                    started.elapsed().as_secs_f64()
                ),
                Err(e) => {
                    failed = true;
                    println!("{path}: ERROR {e}");
                }
            }
        }
        std::process::exit(failed as i32);
    }
    #[cfg(target_os = "macos")]
    if args.iter().any(|a| a == "--make-default") {
        match macos::make_default_player_cli() {
            Ok(msg) => println!("{msg}"),
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        return Ok(());
    }
    // Finder used to pass "-psn_…" on launch; ignore any flags.
    let initial = args.iter().find(|a| !a.starts_with('-')).map(PathBuf::from);

    // Scripted UI test runs shouldn't steal focus (and keystrokes) from whatever you're doing.
    let background = cfg!(feature = "devtools") && std::env::var_os("KOOL_SCRIPT").is_some();
    let event_loop = winit::event_loop::EventLoop::<eframe::UserEvent>::with_user_event().build()?;

    // Must happen after the event loop exists and before it runs, so the launch-time
    // "open these files" Apple Event reaches us.
    #[cfg(target_os = "macos")]
    if !macos::install_delegate_hooks() {
        eprintln!("kool-edit: couldn't hook the app delegate; Finder open-with won't work");
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Kool Edit")
            .with_app_id("dev.kooledit.KoolEdit")
            .with_inner_size([1180.0, 740.0])
            .with_min_inner_size([820.0, 520.0])
            .with_drag_and_drop(true)
            .with_active(!background),
        ..Default::default()
    };
    let mut app = eframe::create_native(
        "Kool Edit",
        options,
        Box::new(move |cc| {
            ui::theme::install(&cc.egui_ctx);
            #[cfg(target_os = "macos")]
            macos::set_context(&cc.egui_ctx);
            Ok(Box::new(app::KoolApp::new(&cc.egui_ctx, initial, false)))
        }),
        &event_loop,
    );
    event_loop.run_app(&mut app)?;
    Ok(())
}
