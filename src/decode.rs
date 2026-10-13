//! Decode any format symphonia understands (WAV, AIFF, MP3, FLAC, OGG, M4A/AAC/ALAC, CAF…) into memory.

use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

use crate::audio::Samples;
use crate::doc::SourceInfo;

pub struct Loaded {
    pub samples: Samples,
    pub info: SourceInfo,
}

/// Decode the whole file. `progress` receives per-mille progress when the length is known.
pub fn load(path: &Path, progress: &AtomicU32) -> Result<Loaded, String> {
    let file = File::open(path).map_err(|e| format!("Couldn't open file: {e}"))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let mut format = symphonia::default::get_probe()
        .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
        .map_err(|e| format!("Unsupported or unrecognized audio format ({e})"))?;

    let track = format.default_track(TrackType::Audio).ok_or("The file has no audio track")?;
    let track_id = track.id;
    let total_frames = track.num_frames;
    let params = track
        .codec_params
        .as_ref()
        .and_then(|p| p.audio())
        .ok_or("The file has no decodable audio track")?
        .clone();

    let codecs = symphonia::default::get_codecs();
    let mut decoder = codecs
        .make_audio_decoder(&params, &AudioDecoderOptions::default())
        .map_err(|e| format!("Unsupported codec ({e})"))?;
    let short_name = codecs.get_audio_decoder(params.codec).map_or("", |d| d.codec.info.short_name);
    let codec = if short_name.is_empty() { "Audio".to_owned() } else { friendly_codec(short_name) };

    let mut rate = params.sample_rate.unwrap_or(0);
    let mut chans: Vec<Vec<f32>> = Vec::new();
    if let Some(n) = total_frames {
        let n_ch = params.channels.as_ref().map_or(2, |c| c.count());
        chans = (0..n_ch).map(|_| Vec::with_capacity(n as usize)).collect();
    }
    let mut packet_buf: Vec<Vec<f32>> = Vec::new();
    let mut decoded_any = false;

    loop {
        let packet = match format.next_packet() {
            Ok(Some(p)) => p,
            Ok(None) => break,
            // A chained stream or a truncated file: keep whatever decoded cleanly.
            Err(Error::ResetRequired) => break,
            Err(e) if decoded_any => {
                eprintln!("kool-edit: stopping decode early: {e}");
                break;
            }
            Err(e) => return Err(format!("Couldn't read the file ({e})")),
        };
        if packet.track_id != track_id {
            continue;
        }
        let buf = match decoder.decode(&packet) {
            Ok(buf) => buf,
            Err(Error::DecodeError(_)) | Err(Error::IoError(_)) => continue,
            Err(e) => return Err(format!("Decoding failed ({e})")),
        };
        if buf.frames() == 0 {
            continue;
        }
        if rate == 0 {
            rate = buf.spec().rate();
        }
        buf.copy_to_vecs_planar::<f32>(&mut packet_buf);
        if !decoded_any {
            chans.resize(packet_buf.len(), Vec::new());
            decoded_any = true;
        }
        for (i, dst) in chans.iter_mut().enumerate() {
            // If a stream changes channel count mid-way, repeat the last channel rather than desync.
            let src = &packet_buf[i.min(packet_buf.len() - 1)];
            dst.extend_from_slice(src);
        }
        if let Some(total) = total_frames.filter(|&t| t > 0) {
            let done = chans[0].len() as u64 * 1000 / total;
            progress.store(done.min(1000) as u32, Ordering::Relaxed);
        }
    }

    if !decoded_any || chans.is_empty() {
        return Err("No audio could be decoded from this file".to_owned());
    }
    for c in &mut chans {
        c.shrink_to_fit();
    }
    let bits = params.bits_per_sample.or_else(|| bits_from_codec(short_name)).filter(|_| is_lossless(&codec));
    Ok(Loaded { samples: Samples { rate: rate.max(1), chans }, info: SourceInfo { codec, bits } })
}

fn is_lossless(codec: &str) -> bool {
    matches!(codec, "PCM" | "FLAC" | "ALAC" | "ADPCM")
}

/// Float PCM doesn't report `bits_per_sample`; recover it from names like `pcm_f32le`.
fn bits_from_codec(short: &str) -> Option<u32> {
    let s = short.to_ascii_lowercase();
    ["f64", "f32", "s32", "u32", "s24", "u24", "s16", "u16", "s8", "u8"]
        .iter()
        .find(|tag| s.contains(*tag))
        .and_then(|tag| tag[1..].parse().ok())
}

fn friendly_codec(short: &str) -> String {
    let s = short.to_ascii_lowercase();
    if s.starts_with("pcm") {
        "PCM".to_owned()
    } else if s.contains("adpcm") {
        "ADPCM".to_owned()
    } else if s == "mp3" || s == "mpa" || s.starts_with("mp") {
        s.to_ascii_uppercase()
    } else {
        short.to_ascii_uppercase()
    }
}
