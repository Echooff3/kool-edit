//! In-memory audio: planar f32 samples plus a min/max peak cache for drawing.

use std::ops::Range;

/// Planar 32-bit float audio. Every channel has the same length.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Samples {
    pub rate: u32,
    pub chans: Vec<Vec<f32>>,
}

impl Samples {
    pub fn silent(rate: u32, n_chans: usize) -> Self {
        Self { rate, chans: vec![Vec::new(); n_chans.max(1)] }
    }

    pub fn len(&self) -> usize {
        self.chans.first().map_or(0, Vec::len)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn n_chans(&self) -> usize {
        self.chans.len()
    }

    pub fn secs(&self, frames: usize) -> f64 {
        frames as f64 / self.rate.max(1) as f64
    }

    /// Copy out a range of frames.
    pub fn extract(&self, range: Range<usize>) -> Samples {
        let range = self.clamp(range);
        Samples { rate: self.rate, chans: self.chans.iter().map(|c| c[range.clone()].to_vec()).collect() }
    }

    /// Replace `range` with `insert` (one vec per channel), returning what was removed.
    pub fn splice(&mut self, range: Range<usize>, insert: &[Vec<f32>]) -> Vec<Vec<f32>> {
        let range = self.clamp(range);
        debug_assert_eq!(insert.len(), self.chans.len());
        self.chans
            .iter_mut()
            .zip(insert)
            .map(|(c, ins)| c.splice(range.clone(), ins.iter().copied()).collect())
            .collect()
    }

    pub fn clamp(&self, range: Range<usize>) -> Range<usize> {
        let len = self.len();
        let end = range.end.min(len);
        range.start.min(end)..end
    }

    /// Convert to the given rate/channel count so it can be pasted into another document.
    pub fn conform(&self, rate: u32, n_chans: usize) -> Vec<Vec<f32>> {
        let src = &self.chans;
        let mut out: Vec<Vec<f32>> = if src.len() == n_chans {
            src.clone()
        } else if n_chans == 1 {
            let n = src.len() as f32;
            (0..1)
                .map(|_| (0..self.len()).map(|i| src.iter().map(|c| c[i]).sum::<f32>() / n).collect())
                .collect()
        } else {
            (0..n_chans).map(|i| src[i.min(src.len() - 1)].clone()).collect()
        };
        if rate != self.rate && self.rate > 0 && rate > 0 {
            out = out.iter().map(|c| resample_linear(c, self.rate, rate)).collect();
        }
        out
    }
}

/// Cheap linear-interpolation resampler, only used when pasting between files of different rates.
pub fn resample_linear(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if input.is_empty() {
        return Vec::new();
    }
    let out_len = ((input.len() as u64 * to as u64) / from as u64).max(1) as usize;
    let step = from as f64 / to as f64;
    (0..out_len)
        .map(|i| {
            let pos = i as f64 * step;
            let i0 = pos.floor() as usize;
            let t = (pos - i0 as f64) as f32;
            let a = input[i0.min(input.len() - 1)];
            let b = input[(i0 + 1).min(input.len() - 1)];
            a + (b - a) * t
        })
        .collect()
}

/// Frames per peak block.
pub const PEAK_BLOCK: usize = 256;

/// Per-channel (min, max) for every `PEAK_BLOCK` frames, so zoomed-out drawing never scans raw samples.
#[derive(Clone, Debug, Default)]
pub struct Peaks {
    chans: Vec<Vec<(f32, f32)>>,
}

impl Peaks {
    pub fn build(s: &Samples) -> Self {
        let mut p = Peaks::default();
        p.update_from(s, 0);
        p
    }

    /// Recompute every block at or after `frame` (everything after an edit point shifts).
    pub fn update_from(&mut self, s: &Samples, frame: usize) {
        self.chans.resize(s.n_chans(), Vec::new());
        let first_block = frame / PEAK_BLOCK;
        for (peaks, data) in self.chans.iter_mut().zip(&s.chans) {
            peaks.truncate(first_block);
            let start = peaks.len() * PEAK_BLOCK;
            peaks.extend(data[start.min(data.len())..].chunks(PEAK_BLOCK).map(min_max));
        }
    }

    /// Min/max of channel `ch` over `range`, using blocks for the middle and raw samples at the edges.
    pub fn range_min_max(&self, s: &Samples, ch: usize, range: Range<usize>) -> Option<(f32, f32)> {
        let range = s.clamp(range);
        if range.is_empty() {
            return None;
        }
        let data = &s.chans[ch];
        if range.len() < PEAK_BLOCK * 2 {
            return Some(min_max(&data[range]));
        }
        let b0 = range.start.div_ceil(PEAK_BLOCK);
        let b1 = range.end / PEAK_BLOCK;
        let mut acc = min_max(&data[range.start..b0 * PEAK_BLOCK]);
        let tail = min_max(&data[b1 * PEAK_BLOCK..range.end]);
        acc = merge(acc, tail);
        if let Some(blocks) = self.chans.get(ch) {
            for &b in &blocks[b0.min(blocks.len())..b1.min(blocks.len())] {
                acc = merge(acc, b);
            }
        }
        Some(acc)
    }
}

fn merge(a: (f32, f32), b: (f32, f32)) -> (f32, f32) {
    (a.0.min(b.0), a.1.max(b.1))
}

fn min_max(xs: &[f32]) -> (f32, f32) {
    xs.iter().fold((f32::INFINITY, f32::NEG_INFINITY), |(lo, hi), &x| (lo.min(x), hi.max(x)))
}

/// Simple destructive effects applied to a range (one vec per channel).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Effect {
    Silence,
    FadeIn,
    FadeOut,
    Normalize,
    Amplify(f32),
    Reverse,
    Invert,
}

impl Effect {
    pub fn name(self) -> &'static str {
        match self {
            Effect::Silence => "Silence",
            Effect::FadeIn => "Fade In",
            Effect::FadeOut => "Fade Out",
            Effect::Normalize => "Normalize",
            Effect::Amplify(_) => "Amplify",
            Effect::Reverse => "Reverse",
            Effect::Invert => "Invert",
        }
    }

    pub fn apply(self, chans: &mut [Vec<f32>]) {
        match self {
            Effect::Silence => chans.iter_mut().for_each(|c| c.fill(0.0)),
            Effect::FadeIn | Effect::FadeOut => {
                for c in chans.iter_mut() {
                    let n = c.len().max(2) - 1;
                    for (i, x) in c.iter_mut().enumerate() {
                        let t = i as f32 / n as f32;
                        *x *= if self == Effect::FadeIn { t } else { 1.0 - t };
                    }
                }
            }
            Effect::Normalize => {
                // Peak normalize to -0.1 dBFS across all channels together.
                let peak = chans.iter().flatten().fold(0.0f32, |m, x| m.max(x.abs()));
                if peak > 1e-9 {
                    let g = 10f32.powf(-0.1 / 20.0) / peak;
                    chans.iter_mut().flatten().for_each(|x| *x *= g);
                }
            }
            Effect::Amplify(db) => {
                let g = 10f32.powf(db / 20.0);
                chans.iter_mut().flatten().for_each(|x| *x *= g);
            }
            Effect::Reverse => chans.iter_mut().for_each(|c| c.reverse()),
            Effect::Invert => chans.iter_mut().flatten().for_each(|x| *x = -*x),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ramp(n: usize) -> Samples {
        Samples { rate: 100, chans: vec![(0..n).map(|i| i as f32).collect(), (0..n).map(|i| -(i as f32)).collect()] }
    }

    #[test]
    fn splice_replaces_and_returns_removed() {
        let mut s = ramp(10);
        let removed = s.splice(2..5, &[vec![9.0], vec![-9.0]]);
        assert_eq!(removed[0], vec![2.0, 3.0, 4.0]);
        assert_eq!(s.chans[0], vec![0.0, 1.0, 9.0, 5.0, 6.0, 7.0, 8.0, 9.0]);
        assert_eq!(s.len(), 8);
    }

    #[test]
    fn peaks_match_brute_force() {
        let n = PEAK_BLOCK * 10 + 37;
        let s = Samples {
            rate: 44100,
            chans: vec![(0..n).map(|i| ((i * 7919) % 1000) as f32 / 500.0 - 1.0).collect()],
        };
        let p = Peaks::build(&s);
        for r in [0..n, 3..PEAK_BLOCK * 4 + 5, PEAK_BLOCK..PEAK_BLOCK * 3, n - 10..n + 50] {
            let r2 = s.clamp(r.clone());
            assert_eq!(p.range_min_max(&s, 0, r), Some(min_max(&s.chans[0][r2])));
        }
    }

    #[test]
    fn peaks_incremental_update() {
        let mut s = ramp(PEAK_BLOCK * 5);
        let mut p = Peaks::build(&s);
        s.splice(PEAK_BLOCK * 2 + 3..PEAK_BLOCK * 3, &[vec![], vec![]]);
        p.update_from(&s, PEAK_BLOCK * 2 + 3);
        let fresh = Peaks::build(&s);
        assert_eq!(p.chans, fresh.chans);
    }

    #[test]
    fn conform_channels_and_rate() {
        let s = ramp(4);
        let mono = s.conform(100, 1);
        assert_eq!(mono, vec![vec![0.0; 4]]);
        let m = Samples { rate: 100, chans: vec![vec![1.0, 2.0]] };
        assert_eq!(m.conform(100, 2), vec![vec![1.0, 2.0], vec![1.0, 2.0]]);
        assert_eq!(m.conform(200, 1)[0].len(), 4);
    }

    #[test]
    fn effects() {
        let mut c = vec![vec![1.0, 1.0, 1.0]];
        Effect::FadeIn.apply(&mut c);
        assert_eq!(c[0], vec![0.0, 0.5, 1.0]);
        let mut c = vec![vec![0.5, -0.25]];
        Effect::Normalize.apply(&mut c);
        assert!((c[0][0] - 0.98855).abs() < 1e-4);
        Effect::Reverse.apply(&mut c);
        assert!(c[0][0] < 0.0);
    }
}
