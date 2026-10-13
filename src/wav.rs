//! Writing WAV files.

use std::path::Path;

use crate::audio::Samples;
use crate::doc::SourceInfo;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WavFormat {
    Pcm16,
    Pcm24,
    Float32,
}

impl WavFormat {
    pub const ALL: [WavFormat; 3] = [WavFormat::Pcm16, WavFormat::Pcm24, WavFormat::Float32];

    pub fn label(self) -> &'static str {
        match self {
            WavFormat::Pcm16 => "16-bit PCM",
            WavFormat::Pcm24 => "24-bit PCM",
            WavFormat::Float32 => "32-bit float",
        }
    }

    pub fn bytes_per_sample(self) -> u64 {
        match self {
            WavFormat::Pcm16 => 2,
            WavFormat::Pcm24 => 3,
            WavFormat::Float32 => 4,
        }
    }

    /// Keep the source's resolution where we can; lossy sources get CD-style 16-bit.
    pub fn for_source(info: &SourceInfo) -> Self {
        match info.bits {
            Some(b) if b > 24 => WavFormat::Float32,
            Some(b) if b > 16 => WavFormat::Pcm24,
            _ => WavFormat::Pcm16,
        }
    }
}

/// Write `samples` as a WAV. Writes to a temp file first so a failed save never clobbers the original.
pub fn save(path: &Path, samples: &Samples, format: WavFormat) -> Result<(), String> {
    let n_ch = samples.n_chans();
    if n_ch == 0 || n_ch > u16::MAX as usize {
        return Err("Nothing to save".to_owned());
    }
    let spec = hound::WavSpec {
        channels: n_ch as u16,
        sample_rate: samples.rate,
        bits_per_sample: match format {
            WavFormat::Pcm16 => 16,
            WavFormat::Pcm24 => 24,
            WavFormat::Float32 => 32,
        },
        sample_format: match format {
            WavFormat::Float32 => hound::SampleFormat::Float,
            _ => hound::SampleFormat::Int,
        },
    };
    let file_name = path.file_name().ok_or("Invalid file name")?.to_string_lossy();
    let tmp = path.with_file_name(format!(".{file_name}.kool-edit-tmp"));

    let write = || -> Result<(), hound::Error> {
        let mut w = hound::WavWriter::create(&tmp, spec)?;
        let len = samples.len();
        match format {
            WavFormat::Pcm16 => {
                let mut w16 = w.get_i16_writer((len * n_ch) as u32);
                for i in 0..len {
                    for c in &samples.chans {
                        w16.write_sample((c[i].clamp(-1.0, 1.0) * 32767.0).round() as i16);
                    }
                }
                w16.flush()?;
            }
            WavFormat::Pcm24 => {
                for i in 0..len {
                    for c in &samples.chans {
                        w.write_sample((c[i].clamp(-1.0, 1.0) * 8_388_607.0).round() as i32)?;
                    }
                }
            }
            WavFormat::Float32 => {
                for i in 0..len {
                    for c in &samples.chans {
                        w.write_sample(c[i])?;
                    }
                }
            }
        }
        w.finalize()
    };

    if let Err(e) = write() {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("Couldn't write WAV: {e}"));
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("Couldn't replace {}: {e}", path.display())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;

    #[test]
    fn wav_roundtrip_through_decoder() {
        let dir = std::env::temp_dir().join(format!("kool-edit-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let s = Samples {
            rate: 22050,
            chans: vec![
                (0..5000).map(|i| (i as f32 * 0.01).sin() * 0.5).collect(),
                (0..5000).map(|i| (i as f32 * 0.02).cos() * 0.25).collect(),
            ],
        };
        for fmt in WavFormat::ALL {
            let path = dir.join(format!("{fmt:?}.wav"));
            save(&path, &s, fmt).unwrap();
            let loaded = crate::decode::load(&path, &AtomicU32::new(0)).unwrap();
            assert_eq!(loaded.samples.rate, 22050);
            assert_eq!(loaded.samples.n_chans(), 2);
            assert_eq!(loaded.samples.len(), 5000);
            let err = loaded.samples.chans[0]
                .iter()
                .zip(&s.chans[0])
                .map(|(a, b)| (a - b).abs())
                .fold(0.0f32, f32::max);
            assert!(err < 1e-4, "{fmt:?} error {err}");
            assert_eq!(WavFormat::for_source(&loaded.info), fmt, "{:?}", loaded.info);
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
