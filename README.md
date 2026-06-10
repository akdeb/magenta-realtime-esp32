<div align="center">

<img src="assets/transparent-circle-logo.png" alt="ELATO logo" width="140" />

# Musical AI Toys with ELATO

### Local musical AI toys powered by your Mac, Magenta RealTime, MLX, and ESP32

*Musical AI Toys with ELATO is a local-first macOS app for creating realtime generative music and streaming it to an ESP32 speaker toy. Touch the ESP32 to interrupt playback, speak a request like "add drums" or "make it lo-fi", and the Mac uses local Whisper STT plus Qwen3.5 tool calls to update the musical bubbles before resuming playback.*

**Apple Silicon · Magenta RealTime 2 · MLX · React · ESP32-S3 · Whisper ASR · Qwen3.5 Tool Calls · Opus Audio**

[![App](https://img.shields.io/badge/App-C%2B%2B%20%2B%20React-yellow)](examples/collider)
[![Hardware](https://img.shields.io/badge/Hardware-ESP32--S3-red?logo=espressif)](arduino)
[![Model](https://img.shields.io/badge/Model-Magenta%20RT%202-blue)](https://magenta.withgoogle.com/mrt2)
[![License](https://img.shields.io/badge/License-Apache%202.0-green)](LICENSE)

<img src="assets/app-view.png" alt="Musical AI Toys with ELATO app" width="640" />

</div>

## What This Is

This repo is built on [Magenta RealTime 2](https://magenta.withgoogle.com/mrt2), an open-weights realtime music generation model. The main app in this fork is the Collider-based macOS app:

- `examples/collider/` — native macOS app, React UI, websocket server, ESP32 audio streaming, voice-command agent.
- `arduino/` — ESP32-S3 firmware for WiFi discovery, touch interrupt, mic streaming, Opus decode, and speaker output.
- `core/` and `magenta_rt/` — Magenta RealTime C++ and Python inference code.

## Why It Is Fun

- **Realtime music generation**: Drag prompt bubbles around a listener puck to steer the music.
- **ESP32 speaker mode**: Stream generated audio over websocket as Opus packets.
- **Voice interrupt**: Touch the ESP32, speak a command, and the Mac pauses music while it listens.
- **Local STT and LLM**: Whisper transcribes locally; Qwen3.5 chooses tool calls locally.
- **Tool-call UI actions**: The agent can call `addBubble(text, nearness)` and `removeBubble(text)`.
- **No cloud required** once your models are downloaded.

## Hardware Requirements

### Mac

Realtime generation requires Apple Silicon.

- `mrt2_small` runs realtime on most Apple Silicon Macs.
- `mrt2_base` sounds better but wants a stronger Pro/Max-class machine for realtime use.

### ESP32

The firmware is currently set up for an ESP32-S3 dev board with:

- I2S microphone
- I2S speaker amp, such as MAX98357A
- touch input
- RGB/status LED
- WiFi on the same network as your Mac

See [arduino/README.md](arduino/README.md) for pin notes.

## Quick Start

### 1. Clone The Repo

```bash
git clone --recurse-submodules https://github.com/akdeb/musical-ai-toys.git
cd musical-ai-toys
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### 2. Install Mac Dependencies

Install Homebrew packages:

```bash
brew install cmake node opus python
```

Install Python tooling and MLX voice dependencies:

```bash
python3 -m pip install --upgrade pip
python3 -m pip install -e ".[mlx]" mlx-whisper mlx-lm huggingface_hub
```

Install the Magenta model resources:

```bash
mrt models init
mrt models download
```

By default, models/resources are stored under:

```text
~/Documents/Magenta/magenta-rt-v2/
```

The app auto-loads `mrt2_base` from that folder when available. You can also pick a model from the app settings.

### 3. Download Local Voice Models

The app expects these Hugging Face models in your local cache:

- `mlx-community/whisper-base.en-mlx`
- `mlx-community/Qwen3.5-4B-MLX-4bit`

Download them once:

```bash
python3 - <<'PY'
from huggingface_hub import snapshot_download

snapshot_download("mlx-community/whisper-base.en-mlx")
snapshot_download("mlx-community/Qwen3.5-4B-MLX-4bit")
PY
```

### 4. Build And Run The macOS App

```bash
cmake . -B build
cmake --build build --target deploy_mrt2_collider -j10
open ~/Applications/"Musical AI Toys with ELATO.app"
```

The deploy target builds the React UI, signs the app locally, bundles `voice_agent.py`, and copies the app to:

```text
~/Applications/Musical AI Toys with ELATO.app
```

## ESP32 Setup

### 1. Install PlatformIO

If you use VS Code, install the PlatformIO extension. Or install the CLI:

```bash
python3 -m pip install platformio
```

### 2. Build And Flash Firmware

Connect the ESP32-S3 over USB, then run:

```bash
cd arduino
pio run -t upload -t monitor
```

The monitor runs at `115200`.

### 3. Connect ESP32 To WiFi

On first boot, the device exposes a WiFi setup portal. Connect to the ELATO access point, enter your WiFi credentials, and put the ESP32 on the same network as the Mac.

The Mac app advertises itself over mDNS and runs the websocket server for the ESP32. Keep the app open while powering or reconnecting the device.

## How To Use It

1. Open `Musical AI Toys with ELATO.app`.
2. Wait for the model to load.
3. Click the large play button to stream music to the ESP32.
4. Click the laptop icon to enable or disable local Mac audio output.
5. Touch the ESP32 to interrupt playback.
6. Speak a command, for example:
   - "add drums to this"
   - "make it lo-fi"
   - "remove guitar"
   - "add saxophone closer"
7. The app shows your transcript, Qwen3.5 calls tools, bubbles update, and ESP32 playback resumes.

## Status Colors

The ESP32 firmware uses LED state to show what is happening:

- Green / processing: connected, waiting, or agent is thinking.
- Yellow / listening: mic is streaming to the Mac.
- Blue / speaking: ESP32 speaker is playing generated audio.

## App Controls

- Large play/pause button: ESP32 playback.
- Laptop icon: Mac/laptop audio output.
- Upload icon: load an audio prompt.
- Right instrument rail: click an instrument to add it as a music bubble.
- Settings icon: model, timing, generation, and buffer controls.

## Project Structure

```text
musical-ai-toys/
├── arduino/                  # ESP32-S3 firmware
├── core/                     # C++ realtime inference engine
├── examples/
│   ├── collider/             # Musical AI Toys with ELATO macOS app
│   │   ├── ui/               # React UI
│   │   └── voice_agent.py    # Whisper + Qwen3.5 tool-call loop
│   ├── common/               # Shared native/React app code
│   └── hello_mrt2/           # Minimal CLI generation example
├── magenta_rt/               # Python package
├── docs/                     # Original Magenta RT docs
└── README.md
```

## Troubleshooting

### App opens but no model loads

Run:

```bash
mrt models init
mrt models download
```

Then reopen the app or choose the model folder from settings.

### ESP32 cannot find the server

- Make sure the Mac and ESP32 are on the same WiFi network.
- Open the macOS app before powering/reconnecting the ESP32.
- Check that no firewall is blocking local network traffic.
- Watch `pio device monitor` for mDNS and websocket logs.

### Whisper works but no tool call happens

Make sure Qwen3.5 is cached:

```bash
python3 - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("mlx-community/Qwen3.5-4B-MLX-4bit", local_files_only=True)
print("Qwen3.5 is cached")
PY
```

### App crashes during startup

Rebuild the latest app:

```bash
cmake --build build --target deploy_mrt2_collider -j10
```

The app queues prompt updates while the model is loading, which avoids racing React startup messages with native MLX model initialization.

## Stack

- Music model: Magenta RealTime 2
- Native inference: C++ `magentart::core` with MLX/Metal
- UI: React, TypeScript, Vite
- Speech-to-text: `mlx-community/whisper-base.en-mlx`
- LLM agent: `mlx-community/Qwen3.5-4B-MLX-4bit`
- Transport: websocket
- ESP32 audio: Opus over websocket, decoded on-device
- Firmware: Arduino + PlatformIO

## Safety

This is an experimental local AI music toy platform. The local LLM can misunderstand speech or choose imperfect tool calls. Use it as a creative tool, supervise children, and avoid treating generated outputs as authoritative.

## Upstream Credits

This project builds on Google Magenta's [Magenta RealTime 2](https://github.com/magenta/magenta-realtime) and the open MLX ecosystem.

## License

See [LICENSE](LICENSE).
