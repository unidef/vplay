# vplay

**vplay** is a native macOS player for video and audio. It opens to a black stage with the vplay logo and a menu panel that fades away when you do not need it, plays almost any file through macOS and FFmpeg, and lets you reshape the picture with sliders, filters and your own shaders.

- [Quick start](#quick-start) · [A tour of the window](#a-tour-of-the-window) · [Keyboard shortcuts](#keyboard-shortcuts)
- [Playlists and shuffle](#playlists-and-shuffle) · [DVD, Blu-ray, VCD and SVCD](#dvd-blu-ray-vcd-and-svcd) · [Audio and subtitle tracks](#audio-video-and-subtitle-tracks)
- [Picture tools](#picture-tools): post-processing, shader and filter editor, FPS display, visualizer
- [Configuration builder](#configuration-builder) · [AirPlay](#airplay)
- [Command line](#command-line) · [Configuration reference](#configuration-reference) · [Building from source](#building-from-source) · [Limitations](#limitations-and-honest-notes)

---

## Quick start

1. Open `vplay.xcodeproj` in Xcode, choose the **vplay** scheme and press Run. (macOS 12.4 or later.)
2. The window opens black with the vplay logo and the **menu panel** on the left.
3. Click **Open File…**, drop a file onto the window, or double-click a file in the panel's browser.
4. Move the mouse to show the controls. They fade four seconds after the pointer stops.

Install [FFmpeg](https://ffmpeg.org) (for example `brew install ffmpeg`) to unlock everything beyond what macOS plays natively: AVI, MKV with unusual codecs, DVDs, Blu-ray streams, subtitle extraction and track details. vplay finds `ffmpeg` and `ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` and your `PATH`.

From a terminal:

```sh
vplay movie.mkv                       # play a file
vplay ~/Music --shuffle               # queue a whole folder in random order
vplay disc /Volumes/MY_DVD            # play a disc
vplay help                            # every command and option
```

The executable lives at `Mac Video Player.app/Contents/MacOS/Mac Video Player`; add it to your `PATH` or create an alias to use these commands.

---

## A tour of the window

| Part | What it does |
| --- | --- |
| **Black stage with the vplay logo** | Shown at launch and after Stop. The logo is replaced by the video as soon as playback starts. Set `backgroundImage` in the configuration to use your own picture. |
| **Menu panel (the HUD)** | Every feature as a button: open a file, URL, folder or disc; playlist and shuffle; tracks and subtitles; AirPlay; visualizer; FPS display; post-processing; shader editor; configuration builder; settings; help. It appears at launch, fades after a few seconds, returns whenever you move the mouse while nothing is playing, when you touch the left edge during playback, or when you press **Tab**. A built-in file browser sits underneath; the disc and folder buttons in its header jump to your volumes or play the current folder. |
| **Playback controls** | Previous, play/pause, next, stop, position, time, volume, shuffle, repeat, tracks and subtitles, playlist, full screen and the menu. They fade four seconds after the mouse enters, moves in or leaves the window. |
| **AirPlay overlay** | The AirPlay button floats in the top-right corner and follows the same four-second fade. |
| **Information card** | When playback starts, a card in the top-left shows the title, artist or album, duration, video and audio formats, subtitle count, container and bitrate, then fades away after about eight seconds. Press **I** to show it again. |
| **Subtitles** | Drawn at the bottom of the picture, above the controls. |
| **FPS pill** | Optional. Shows the frames per second the player is actually delivering, next to the file's own rate (`FPS 23.9 / 23.98`). |
| **Right-click** | A quick menu with the most-used actions. |

The menu bar mirrors everything: **File**, **Playback**, **Audio**, **Video**, **Subtitles**, **Window** and **Help**. The *Audio Track*, *Video Track* and *Subtitles* menus fill in from the file that is playing.

---

## Keyboard shortcuts

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| Space | Play / pause | N / P | Next / previous item |
| Tab | Show or hide the menu panel | S | Shuffle on / off |
| ← / → | Seek 5 seconds | R | Repeat off / all / one |
| ↑ / ↓ | Volume | M | Mute |
| F | Full screen | I | Show media information |
| V | Visualizer over video | D | FPS display |
| `[` / `]` | Slower / faster | Esc | Hide the menu panel |
| ⌘O | Open file | ⇧⌘O | Open folder or playlist |
| ⌘U | Open URL | ⌥⌘O | Open disc |
| ⌘L | Playlist | ⌘B | Configuration builder |
| ⌘, | Settings | ⌘. | Stop |

Letter keys only act on the player window, so typing in the editors never triggers them. Double-click the picture for full screen.

---

## Playlists and shuffle

vplay always plays from a queue. Opening one file creates a queue of one; opening several files, a folder, or a playlist file fills the queue.

- **In the window:** *Open File…* accepts several files; *Open Folder…* queues folders (searched recursively) and `.m3u`, `.m3u8` and `.pls` playlists; dropping any mix of files, folders and discs onto the window does the same.
- **Playlist panel** (⌘L): drag rows to reorder, drop more files in, remove, clear, save as `.m3u`, load a playlist, tick **Shuffle** and choose **Repeat** (off, whole list, one item). Double-click an item to play it.
- **Shuffle** plays every item once in random order, starting from the current one, then reshuffles on repeat. It never jumps tracks when you turn it on or off.
- **Next / previous** follow shuffle and repeat. *Previous* restarts the current item when you are more than four seconds in.
- **Command line:**

```sh
vplay play a.mkv b.mp3 ~/Music/Album --shuffle        # files and folders, shuffled
vplay play --playlist evening.m3u --repeat all        # playlist file, repeating
vplay playlist show ~/Music --shuffle                 # preview what would play
vplay playlist create out.m3u ~/Music --shuffle       # write a (shuffled) M3U playlist
```

Shuffle, repeat, FPS and visualizer choices are remembered in `~/Library/Application Support/vplay/config.json`.

---

## DVD, Blu-ray, VCD and SVCD

Choose **Open Disc…** (⌥⌘O), click the disc button in the browser header, drop a disc onto the window, or run `vplay disc`. vplay accepts:

| Source | What plays |
| --- | --- |
| Mounted disc in `/Volumes`, or a ripped folder that contains `VIDEO_TS` | **DVD**: the title set with the most data (normally the main feature), joined into one program |
| Folder containing `BDMV` | **Blu-ray**: the largest stream file (normally the main feature) |
| Folder containing `MPEGAV` or `VCD` | **VCD**: every track becomes a playlist item |
| Folder containing `MPEG2` or `SVCD` | **SVCD**: every track becomes a playlist item |
| `.iso`, `.img`, `.toast`, `.cdr`, `.dmg`, `.udf` image | Mounted read-only, then treated as above |

```sh
vplay disc                       # first disc that is mounted
vplay disc-list                  # what is mounted, and its type
vplay disc ~/Rips/MyMovie.iso
```

Discs are converted on the fly with FFmpeg: playback starts within a couple of seconds while conversion continues ahead of the playhead, so you can seek (a distant seek restarts conversion from that point). Interlaced DVD video is deinterlaced automatically. Post-processing, shaders, subtitles and the FPS display all work on disc playback.

Copy-protected commercial discs (CSS on DVD, AACS on Blu-ray) cannot be decrypted by vplay or by a stock FFmpeg, and disc menus are not interpreted. Home-made, unprotected and ripped discs work.

---

## Audio, video and subtitle tracks

Use the speech-bubble button, the panel's **Tracks & Subtitles**, or the *Audio*, *Video* and *Subtitles* menus. Track names include language, codec and channel layout, read with `ffprobe`.

- **Audio tracks** switch instantly for files macOS plays natively; otherwise playback restarts at the same position with the chosen track.
- **Video tracks** (alternate angles or streams) restart playback at the same position.
- **Subtitles:** text subtitles inside the file (SRT, ASS, WebVTT, `mov_text`) are extracted and drawn by vplay. Picture-based subtitles (DVD and Blu-ray) are drawn onto the video by FFmpeg, which restarts playback at the same position. **Load Subtitle File…** adds an external `.srt`, `.vtt`, `.ass` or `.ssa`. A file named like the video (`Movie.srt` beside `Movie.mkv`) loads automatically.
- `vplay tracks FILE` lists every track from the terminal.

---

## Picture tools

### Post-processing

*Panel → Post-Processing…* (⌥⌘P). Sliders for brightness, contrast, saturation, hue, gamma, exposure, warmth, sharpness, noise reduction, blur and vignette, an invert switch, and one-click looks (Cinema, Vivid, Noir, Warm Sunset, Cool Night, Clean & Sharp, Soft Dream). Changes apply live, even while paused, and are remembered. From the command line:

```sh
vplay play movie.mkv --post "saturation=1.3,contrast=1.1,sharpness=0.5"
```

### Shader and filter editor

*Panel → Shader Editor* (⌥⌘E) has a live preview that uses the frame that is playing now, or a test pattern when nothing is.

- **Shader**: a Core Image color kernel. The preview updates as you type, with compile errors shown below the editor. Insert a template (invert, grayscale, sepia, posterize, threshold, teal & orange, scanlines) to start.
- **Filter chain**: stack and reorder built-in filters such as `sepia:0.6`, `noir`, `bloom:1`, `comic`, `zoomblur:10`. Select a row to change its amount. `vplay effect-list` shows all of them.
- **Apply to Player** puts both on the playing video immediately. **Save Preset…** stores them as JSON; **Save Shader…** writes a `.cikernel` file you can use with `--shader`.

```c
kernel vec4 effect(__sample pixel) {
    return vec4(pixel.a - pixel.rgb, pixel.a);     // invert
}
```

Kernels use Apple's older Core Image kernel language: one `__sample` argument, a `vec4` result. Multi-pass shaders, Metal shaders and custom uniforms are not supported.

### FPS display

Turn it on from the panel, the Video menu (⌥⌘D) or `D`. `vplay play movie.mkv --fps` starts with it on.

### Audio visualizer

Audio-only files (music, podcasts) always show a live spectrum, taken from the actual audio. Press `V` (or *Audio → Visualizer over Video*) to also show it along the bottom of a video; *Next Visualizer Style* cycles bars, mirror and ring. Spectrum analysis works on files macOS plays directly. For media vplay converts (discs, unusual formats), the visualizer shows a gentle idle animation instead.

---

## Configuration builder

Open it with ⌘B, the panel's **Config Builder**, or from a terminal:

```sh
vplay configure                               # empty builder
vplay configure my-setup.json                 # load a saved setup
vplay configure --input ~/Movies/film.mkv     # start with media chosen
```

In one window you can pick the media (a file, URL, folder, playlist or disc), choose the playback backend, and build an **ordered chain of stages** that mixes:

| Stage type | What it is | Example |
| --- | --- | --- |
| `video` | FFmpeg video filter | `eq=contrast=1.1,unsharp=5:5:0.8` |
| `audio` | FFmpeg audio filter | `loudnorm`, `aresample=48000` |
| `effect` | Built-in Core Image effect | `sepia:0.6` |
| `shader` | Core Image kernel file | `~/shaders/glow.cikernel` |

FFmpeg video stages run first, then effects and shaders in order; audio stages form their own chain. Reorder, remove, load shaders or write one, set volume, loop and shuffle, then **Save Config…**, **Apply** or **Launch Media**. The builder also opens the shader editor and post-processing windows. When a chain needs FFmpeg, vplay converts the media on the fly and plays the result.

---

## AirPlay

Start playback, then click the AirPlay button in the top-right overlay (or **AirPlay** in the panel). The overlay appears whenever the pointer enters, moves in or leaves the window and fades four seconds later; it stays while the device list is open. AirPlay works with media macOS plays directly and with converted media.

---

## Supported media

vplay hands everything macOS can decode to the system player, and sends the rest through FFmpeg, so the practical rule is: **if FFmpeg can read it, vplay can play it.** That covers essentially all common video (MP4, MOV, MKV, WebM, AVI, WMV/ASF, FLV, MPEG-PS/TS, VOB, M2TS, OGV, 3GP, RealMedia, MXF and more), audio (MP3, AAC, M4A, FLAC, ALAC, WAV, AIFF, Ogg/Opus, WMA, APE, WavPack, AC-3/E-AC-3, DTS, MKA, CAF and more) and network streams (HTTP(S), HLS, RTSP, RTMP, UDP). The file chooser accepts every file. Without FFmpeg installed, playback is limited to what macOS itself supports.

---

## Command line

```text
vplay                                  open the player
vplay FILE|FOLDER|URL... [OPTIONS]     play (same as `vplay play`)
vplay play INPUT... [OPTIONS]          play files, folders, playlists, discs or URLs
vplay disc [PATH]   vplay disc-list    play a disc / list mounted discs
vplay playlist create OUT.m3u INPUT... [--shuffle]
vplay playlist show INPUT... [--shuffle]
vplay configure [JSON] [--input FILE]  configuration builder
vplay tracks FILE   vplay info FILE    list tracks / print metadata as JSON
vplay effect-list                      built-in effects
vplay device-list   vplay device-set UID
vplay config-save FILE
vplay ffmpeg ARGS...   vplay ffmpeg-play ARGS...   forward to ffmpeg / ffplay
```

| Option | Meaning |
| --- | --- |
| `--shuffle`, `--repeat off\|all\|one`, `--playlist FILE` | Queue behavior |
| `--fps`, `--visualizer`, `--visualizer-style bars\|mirror\|ring`, `--no-metadata` | Display options |
| `--post "brightness=0.1,contrast=1.2"` | Post-processing (brightness contrast saturation hue gamma exposure warmth sharpness noiseReduction blur vignette) |
| `--effect NAME[:AMOUNT]`, `--shader FILE` | Core Image effect / kernel |
| `--vf GRAPH`, `--af GRAPH` | FFmpeg video / audio filter graphs (converted playback) |
| `--audio-layout auto\|stereo\|5.1` | Force stereo or synthesize 5.1 |
| `--backend auto\|native\|prepared\|ffplay` | Choose how media is played |
| `--config-load FILE` | Load a JSON configuration; flags override it |
| `--loop`, `--mute`, `--volume 0..1`, `--rate N`, `--audio UID` | Basics |
| `--audio-sample-rate auto\|max\|HZ`, `--upscale 1..4`, `--scaler metal\|lanczos` | Quality |
| `--deinterlace`, `--inverse-telecine`, `--field-order auto\|tff\|bff` | Interlaced and telecined sources |
| `--ffmpeg`, `--ffplay-arg TOKEN` | Use an external FFplay window |

Backends: **auto** plays natively and falls back to FFmpeg conversion; **native** never converts; **prepared** always converts; **ffplay** uses FFplay's own window (requires `ffplay`).

---

## Audio quality and processing

The sample-rate, deinterlacing, inverse-telecine and upscaling options are unchanged from earlier versions; see `examples/quality-metal.json`, `examples/quality-interlaced.json` and `examples/surround.json`.

- `audioSampleRate`: `auto` leaves the output device alone, `max` asks Core Audio for its highest nominal rate, or give Hz as a string. This changes the **system** output device and is not restored when playback stops.
- `deinterlace` (BWDIF) or `inverseTelecine` (field match, deinterlace, decimate): choose one. They need the FFmpeg path.
- `upscale` 1–4× with `scaler` `metal` (Lanczos on the GPU, native playback, 8192-pixel limit) or `lanczos` (FFmpeg CPU scaling). This is interpolation, not AI super-resolution.
- `audioLayout` `5.1` synthesizes surround from stereo; it does not recover discrete channels.

## Full FFmpeg access

```sh
vplay ffmpeg -i input.mov -c:v libx264 -crf 20 -c:a aac -b:a 192k output.mp4
vplay ffmpeg -ss 10 -i input.mp4 -frames:v 1 frame.png
vplay ffmpeg-play -vf hflip input.mp4
```

Arguments are forwarded unchanged and the exit status returned. In *Settings*, `ffmpegArguments` runs the same kind of job from the GUI: one array element per argument, no shell quoting, and include the input and output paths (use `-nostdin` and `-n` or `-y`).

---

## Configuration reference

Defaults load from `~/Library/Application Support/vplay/config.json`; `--config-load` and the builder use the same format. Unknown keys are preserved.

| Key | Type / default | Purpose |
| --- | --- | --- |
| `volume`, `rate` | number / 1 | Volume 0–1, playback speed |
| `loop`, `mute`, `ffmpeg` | boolean / false | Repeat the current item, mute, use FFplay |
| `shuffle` | boolean / false | Play the queue in random order |
| `repeat` | `off` \| `all` \| `one` | Queue repeat |
| `showFPS`, `visualizer` | boolean / false | FPS pill; visualizer over video |
| `visualizerStyle` | `bars` \| `mirror` \| `ring` | Visualizer look |
| `showMetadata` | boolean / true | Information card at the start |
| `postProcessing` | object | Slider values, `enabled`, `filterChain`, `shaderSource` |
| `playlist` | array of strings | Items to queue when vplay starts with no inputs |
| `backgroundImage` | string | Picture shown on the empty stage instead of the logo |
| `playbackBackend` | `auto` \| `native` \| `prepared` \| `ffplay` | How media is played |
| `effect`, `shader` | string | Native effect / kernel path |
| `effectChain` | array of `{type, value}` | Ordered stages (see the builder) |
| `vf`, `af` | string | FFmpeg filter graphs |
| `ffplayArguments`, `ffmpegArguments` | array of strings | Raw FFplay / FFmpeg arguments |
| `audioDevice`, `audioLayout`, `audioSampleRate` | string | Audio output options |
| `deinterlace`, `inverseTelecine`, `fieldOrder`, `upscale`, `scaler` | see above | Video quality options |

---

## Building from source

Open `vplay.xcodeproj`, scheme **vplay**. The project uses `FFMPEG_ROOT = /usr/local` only for optional FFmpeg headers (`VPFFmpeg.h`); the app itself runs FFmpeg as a subprocess.

`tools/make_assets.swift` regenerates the app icon (`vplay/AppIcon.icns`) and the logo shown on the empty stage (`vplay/vplay-splash.png`):

```sh
swift tools/make_assets.swift
```

---

## Limitations and honest notes

- **Copy protection:** CSS, AACS and BD+ discs are not supported, and disc menus, chapters-by-menu and angle menus are not interpreted. Blu-ray plays the largest stream, which is the feature for ordinary discs but not for every layout.
- **Converted playback** (anything macOS cannot play natively) needs FFmpeg with VideoToolbox H.264 encoding and HLS output; without them vplay converts the whole file before playing, which can take a long time for movies. Seeking far ahead in converted media restarts conversion.
- **Visualizer:** real spectrum only for natively played media; converted media shows an idle animation.
- **Shaders** use Apple's deprecated Core Image kernel language and can only transform one pixel at a time.
- **FFplay backend:** opens its own window; vplay's controls, effects and visualizer do not apply, and `ffplay` must be installed (it is not part of every FFmpeg build).
- **Seeking from the command line:** `pause`, `seek`, `stop` and similar commands report that they need a running player; there is no remote control between processes. `screenshot`, `export` and `trim` remain unfinished; use `vplay ffmpeg` for those jobs.
- **AirPlay** was not exercised against real receivers in development, and FFplay playback and physical high-sample-rate or 5.1 output are unverified.
- Verified during development: the project builds; the empty stage, menu panel and chrome skin render; converted playback starts within seconds with effects applied; post-processing, the FPS display, the information card, DVD folders (synthetic), folder queues with shuffle, audio visualizer, and the shader editor's live preview were exercised with generated test media.
