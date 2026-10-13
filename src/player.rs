//! Playback through the default output device.
//!
//! A fresh cpal stream is opened on every play so device changes (headphones, AirPods) just work,
//! and nothing runs on the audio thread while stopped. The UI talks to the callback via atomics.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, RwLock};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SizedSample};

use crate::audio::Samples;

const NO_SEEK: u64 = u64::MAX;

#[derive(Default)]
struct Shared {
    playing: AtomicBool,
    looping: AtomicBool,
    /// Current position in source frames, as f64 bits.
    pos: AtomicU64,
    end: AtomicU64,
    loop_start: AtomicU64,
    seek: AtomicU64,
    /// Max |sample| since the UI last looked, per channel, as f32 bits (non-negative floats order like their bits).
    peaks: [AtomicU32; 2],
}

pub struct Player {
    shared: Arc<Shared>,
    stream: Option<cpal::Stream>,
}

impl Default for Player {
    fn default() -> Self {
        let shared = Shared::default();
        shared.seek.store(NO_SEEK, Relaxed);
        Player { shared: Arc::new(shared), stream: None }
    }
}

impl Player {
    pub fn is_playing(&self) -> bool {
        self.stream.is_some() && self.shared.playing.load(Relaxed)
    }

    /// True once the callback reached the end of a non-looping range; the caller should `stop()`.
    pub fn finished(&self) -> bool {
        self.stream.is_some() && !self.shared.playing.load(Relaxed)
    }

    pub fn position(&self) -> usize {
        let s = self.shared.seek.load(Relaxed);
        if s != NO_SEEK {
            return s as usize;
        }
        f64::from_bits(self.shared.pos.load(Relaxed)).max(0.0) as usize
    }

    pub fn set_looping(&self, looping: bool) {
        self.shared.looping.store(looping, Relaxed);
    }

    /// Jump the playhead and change where playback ends/loops, without restarting the stream.
    pub fn retarget(&self, pos: usize, end: usize, loop_start: usize) {
        self.shared.end.store(end as u64, Relaxed);
        self.shared.loop_start.store(loop_start as u64, Relaxed);
        self.shared.seek.store(pos as u64, Relaxed);
    }

    pub fn seek(&self, pos: usize) {
        self.shared.seek.store(pos as u64, Relaxed);
    }

    /// Peak levels since the last call (linear, 0..1+).
    pub fn take_peaks(&self) -> [f32; 2] {
        [0, 1].map(|i| f32::from_bits(self.shared.peaks[i].swap(0, Relaxed)))
    }

    pub fn stop(&mut self) {
        self.shared.playing.store(false, Relaxed);
        self.stream = None;
    }

    pub fn play(
        &mut self,
        data: Arc<RwLock<Samples>>,
        from: usize,
        end: usize,
        loop_start: usize,
        looping: bool,
    ) -> Result<(), String> {
        self.stop();
        let s = &self.shared;
        s.pos.store((from as f64).to_bits(), Relaxed);
        s.seek.store(NO_SEEK, Relaxed);
        s.end.store(end as u64, Relaxed);
        s.loop_start.store(loop_start as u64, Relaxed);
        s.looping.store(looping, Relaxed);
        s.playing.store(true, Relaxed);

        let host = cpal::default_host();
        let device = host.default_output_device().ok_or("No audio output device found")?;
        let config = device.default_output_config().map_err(|e| format!("Audio device error: {e}"))?;
        let fmt = config.sample_format();
        let config: cpal::StreamConfig = config.into();

        use cpal::SampleFormat as F;
        let stream = match fmt {
            F::F32 => build::<f32>(&device, config, data, self.shared.clone()),
            F::F64 => build::<f64>(&device, config, data, self.shared.clone()),
            F::I16 => build::<i16>(&device, config, data, self.shared.clone()),
            F::I32 => build::<i32>(&device, config, data, self.shared.clone()),
            F::U16 => build::<u16>(&device, config, data, self.shared.clone()),
            F::U8 => build::<u8>(&device, config, data, self.shared.clone()),
            other => Err(format!("Unsupported output sample format {other}")),
        };
        let stream = match stream {
            Ok(st) => st,
            Err(e) => {
                s.playing.store(false, Relaxed);
                return Err(e);
            }
        };
        stream.play().map_err(|e| format!("Couldn't start playback: {e}"))?;
        self.stream = Some(stream);
        Ok(())
    }
}

fn build<T>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    data: Arc<RwLock<Samples>>,
    shared: Arc<Shared>,
) -> Result<cpal::Stream, String>
where
    T: SizedSample + FromSample<f32> + Send + 'static,
{
    let out_rate = config.sample_rate as f64;
    let out_ch = config.channels as usize;
    let silence = T::from_sample(0.0f32);

    let callback = move |out: &mut [T], _: &cpal::OutputCallbackInfo| {
        // Never block the audio thread: if the UI is mid-edit, output silence for this buffer.
        let guard = match data.try_read() {
            Ok(g) if shared.playing.load(Relaxed) => g,
            _ => {
                out.fill(silence);
                return;
            }
        };
        let src = &*guard;
        let len = src.len() as f64;
        let step = src.rate as f64 / out_rate;
        let mut pos = f64::from_bits(shared.pos.load(Relaxed));
        let seek = shared.seek.swap(NO_SEEK, Relaxed);
        if seek != NO_SEEK {
            pos = seek as f64;
        }
        let end = (shared.end.load(Relaxed) as f64).min(len);
        let loop_start = shared.loop_start.load(Relaxed) as f64;
        let looping = shared.looping.load(Relaxed) && end - loop_start >= 1.0;
        let (mut peak_l, mut peak_r) = (0.0f32, 0.0f32);
        let mut done = false;

        for frame in out.chunks_mut(out_ch) {
            if pos >= end {
                if looping {
                    pos = loop_start + (pos - end).min(end - loop_start - 1.0);
                } else {
                    done = true;
                }
            }
            if done {
                frame.fill(silence);
                continue;
            }
            let l = interp(&src.chans[0], pos);
            let r = if src.n_chans() > 1 { interp(&src.chans[1], pos) } else { l };
            peak_l = peak_l.max(l.abs());
            peak_r = peak_r.max(r.abs());
            match frame.len() {
                1 => frame[0] = T::from_sample((l + r) * 0.5),
                _ => {
                    frame[0] = T::from_sample(l);
                    frame[1] = T::from_sample(r);
                    frame[2..].fill(silence);
                }
            }
            pos += step;
        }

        shared.pos.store(pos.min(end.max(0.0)).to_bits(), Relaxed);
        shared.peaks[0].fetch_max(peak_l.to_bits(), Relaxed);
        shared.peaks[1].fetch_max(peak_r.to_bits(), Relaxed);
        if done {
            shared.playing.store(false, Relaxed);
        }
    };

    device
        .build_output_stream(config, callback, |e| eprintln!("kool-edit: audio stream error: {e}"), None)
        .map_err(|e| format!("Couldn't open audio output: {e}"))
}

/// 4-point Catmull-Rom interpolation; exact at integer positions, so same-rate playback is bit-perfect.
fn interp(c: &[f32], pos: f64) -> f32 {
    let n = c.len();
    if n == 0 {
        return 0.0;
    }
    let i = pos.floor() as isize;
    let t = (pos - i as f64) as f32;
    let at = |k: isize| c[k.clamp(0, n as isize - 1) as usize];
    let (y0, y1, y2, y3) = (at(i - 1), at(i), at(i + 1), at(i + 2));
    if t == 0.0 {
        return y1;
    }
    let a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3;
    let b = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    let c1 = -0.5 * y0 + 0.5 * y2;
    ((a * t + b) * t + c1) * t + y1
}

#[cfg(test)]
mod tests {
    use super::interp;

    #[test]
    fn interp_exact_on_samples_and_smooth_between() {
        let c = [0.0, 1.0, 2.0, 3.0];
        assert_eq!(interp(&c, 2.0), 2.0);
        assert!((interp(&c, 1.5) - 1.5).abs() < 1e-6);
    }
}
