# Persona 4 Golden for iOS

A static recompilation of **Persona 4 Golden** (Nintendo Switch) into a native iPhone / iPad app. The game's own
AArch64 code is lifted to C ahead of time and compiled for iOS; its NVN graphics run on Metal, its services on a small
Horizon runtime. It is not an emulator.

**No game files are included, and none are in this repository.** You need your own copy of the game (the Switch
version, 1.0.0, title `010062B01525C000`) and the keys of your own console. The recompiled code is built on your Mac from
your files, and the IPA it makes holds that code: it is for your own device; don't share it.

## Features

- Locked 60 fps (or the game's original 30, in the launcher).
- On-screen controls in the game's yellow-and-black style: a floating left stick, a camera drag on the right, ABXY,
  d-pad, shoulders, `-` / `+`. They hide while a game controller is connected (or set them always on / off).
- A launcher that checks your game files and shows your save folder.
- **Your save in a folder**: the game's save data is `Save/` in the app's Documents (Files app → On My iPhone →
  Persona 4 Golden → Save). Copy a save from MeloNX / Ryujinx (the files in `bis/user/save/<id>/<user>/`) in, or copy
  yours out.
- Resolution scale, frame-rate counter, haptics, controller support.

## Building (on a Mac with Xcode)

1. **Extract your game** from your own NSZ / NSP with your own `prod.keys`:

   ```
   python3 -m venv venv && venv/bin/pip install nsz cryptography zstandard unicorn capstone lz4 pillow
   venv/bin/python tools/nsz_extract.py "Persona 4 Golden.nsz" prod.keys work
   ```

   This writes `work/exefs` (the code) and `work/romfs` (about 9 GB of game data).

2. **SDL3 and FFmpeg for iOS** in one folder (`include/`, `lib/`): SDL 3.4+ built for `iphoneos` (static), FFmpeg 7
   configured for iOS with the VP9, VP8, H.264, Vorbis and AAC decoders and swscale (see `ios/build.sh`).

3. **Build the IPA:**

   ```
   GAME=work DEPS=<that folder> PY="venv/bin/python" ios/build.sh
   ```

   The first build lifts the game's code to C (a few seconds) and compiles about 350 files (a few minutes).

4. **Install** the IPA with your sideloading tool (ESign, AltStore, SideStore, Sideloadly). Let it keep the
   *Increased Memory Limit* entitlement. Then copy `exefs/` and `romfs/` into the app's `game` folder with the Files
   app, or over USB: `ios/push-game-files.sh work`.

## Running it on a Mac (development)

`make gen && make -j2`, then `build/p4g work`. `P4G_OFFSCREEN=1` renders without a window,
`P4G_INPUT="600:A:6,..."` scripts the controller, `P4G_WINDOW_SHOT=<frame>` saves a screenshot.

## How it works

- `tools/` — the recompiler: `gen.py` / `lifter.py` lift each module (`main`, `sdk`) to C; `nsz_extract.py` reads
  your NSZ / NSP; `builds.py` / `patches_p4g.py` hold the per-build knowledge.
- `runtime/` — the Horizon kernel and services (`kernel.c`, `ipc.c`, `services/`), host implementations of SDK
  libraries (`hle/`: NVN bootstrap, `vi`, the movie decoder on FFmpeg), the NVN → Metal renderer and the Maxwell
  shader translator (`nvn/`).
- `ios/` — the app: launcher, touch controls, build and packaging scripts.

## Credits

- **[LAS Recomp](https://github.com/peiikai/LASRecomp)** (MIT, Peiikai): the recompiler, the runtime and the NVN-on-Metal
  renderer this port is built from (`LICENSE.LASRecomp`).
- **[nxnative](https://github.com/seedds/nxnative)** (MIT, seedds): its notes and host code were the reference for SDK
  14 behaviour, CRI Sofdec2 movies and the decoder protocol.
- **SMAA** (MIT, `third_party/smaa`), **SDL3** (zlib), **FFmpeg** (LGPL 2.1, linked statically: rebuild with your own
  FFmpeg to replace it).

Persona 4 Golden is © ATLUS / SEGA. This project is not affiliated with them or with Nintendo.
