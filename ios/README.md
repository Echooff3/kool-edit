# Kool Edit for iPhone and iPad

The same Cool Edit look as the macOS app (grey Windows 2000 chrome, the
black waveform with the green wave, the navy-on-white selection, the
seven-segment LCD and the LED level meter), rebuilt in SwiftUI for touch,
plus what a phone is for: recording yourself jamming, marking the good
moments, and sharing just those bits.

## What it does

- **Records** from the built-in mic or an audio interface (48 kHz, 24-bit,
  mono or stereo) with the voice processing off, so a guitar isn't squashed.
  The meter runs before you hit Record so you can set levels. Recording
  carries on with the screen locked, and a phone call or a cable pulled out
  stops it cleanly with what was recorded saved. It shows how many hours of
  space are left.
- **Marks** moments: tap the flag while recording or playing. Markers show
  on the waveform and in a list; tap one to jump there, long-press the
  waveform (or use the list) to select from one marker to the next.
- **Plays** the selection, or from the cursor to the end, with Stop (back
  to where it started), Pause, Loop, skip ±5 s, start and end, like the
  macOS transport. The view follows the playhead, and it keeps playing in
  the background.
- **Edits** like the macOS app: Cut, Copy, Paste (insert at the cursor or
  replace the selection, converting rate and channels between takes),
  Delete, Trim, and ten steps of Undo/Redo.
- **Effects** for the selection, or the whole take with nothing selected:
  Fade In, Fade Out, Normalize (-0.1 dB), Amplify, Silence, Reverse, Invert.
- **Shares** the selection (or the whole take) as M4A (AAC), 16-bit WAV or
  24-bit WAV through the share sheet (Messages, AirDrop, Save to Files…),
  named after the take and the times, with 5 ms fades on the ends so clips
  don't click. **Save Selection as New Take** keeps a moment in the library.
- **Imports** anything iOS can read (WAV, AIFF, MP3, AAC/M4A, ALAC, FLAC,
  CAF) from Files, from "Open in Kool Edit" in other apps, or by dragging
  files onto the app in Finder's iPhone file sharing.

## Touch

| Gesture | Does |
| --- | --- |
| Drag on the waveform | Select (drag near an edge to move that edge; edges snap to markers, and the view scrolls at the sides) |
| Drag on the time ruler | Scrub the cursor |
| Tap | Put the cursor there (seeks while playing) |
| Tap a marker's flag on the ruler | Jump to it |
| Long-press | Select between the markers either side |
| Pinch | Zoom, down to individual samples |
| Two-finger drag | Scroll (with momentum) |
| Drag on the overview strip | Move the view there |
| Tap a Sel time | Type an exact Begin, End or Length |
| Tap the level meter | Reset the clip lights |

The take's name at the top is a menu (rename, share the whole take).
Landscape trades the LCD and fields for a taller waveform.

## How it's built

Takes live in Application Support, one folder each: the audio as a 24-bit
CAF, `take.json` (name, markers, a thumbnail waveform) and a min/max peak
file so even an hour-long jam opens instantly. Nothing is ever loaded whole:
playback streams from the file, the waveform draws from the peaks (or reads
just the samples on screen when zoomed in close), and every edit streams the
take into a new file, keeping the old one for undo until you leave the take.

| File | Contents |
| --- | --- |
| `Audio/AudioIO.swift` | Reading and writing takes in chunks, channel and sample-rate conversion |
| `Audio/Peaks.swift` | The multi-level min/max peaks, saved beside the audio |
| `Audio/Edits.swift` | Edits and effects, rendered file to file |
| `Audio/Exporter.swift` | M4A/WAV export for sharing |
| `Audio/Player.swift`, `Audio/Recorder.swift` | AVAudioEngine playback and recording |
| `Model/` | Takes, the library, the clipboard, the view, the editor |
| `Views/` | The Cool Edit chrome, the UIKit waveform, the screens |

## Building

Open `KoolEdit.xcodeproj` in Xcode 26, pick your team under Signing &
Capabilities, and run on your iPhone (or a simulator). Bundle ID
`com.trilsoft.kooledit`, iOS 17 or later.

The tests cover the audio code (peaks, every edit and effect, export, import,
sample-rate conversion) and the view maths:

```sh
xcodebuild test -project KoolEdit.xcodeproj -scheme KoolEdit -destination 'platform=iOS Simulator,name=iPhone 17'
```

The icon is the macOS one, cropped to fill the square (from the repository root):

```sh
cargo run --release --bin make-icon -- /tmp/kool.iconset
swift ios/scripts/make-icon.swift /tmp/kool.iconset/icon_512x512@2x.png ios/KoolEdit/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
