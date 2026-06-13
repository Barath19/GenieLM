# ShakeSight 👁

Shake your mouse anywhere on macOS → it screenshots your screen, asks a **local
Gemma vision model** what you're looking at, and floats the answer next to your
cursor. No cloud, no API keys, runs fully on-device.

Hackathon project (Pioneer / Fastino Labs). Built native in Swift.

## Milestones

- [x] **M1 — Shake → screenshot → Gemma → floating answer** (this build)
- [ ] M2 — Ask follow-up questions about the same screenshot (multi-turn)
- [ ] M3 — Drag-select a region; auto-detect error / code / form context
- [ ] M4 — **Take actions on screen** (Accessibility API: click & type, with approval)
- [ ] M5 — Agentic plan→act→observe loop; swap Ollama for native MLX-VLM

## Requirements

- macOS 14+ (built/tested on macOS 27, Apple Silicon)
- [Ollama](https://ollama.com) with a vision model:
  ```bash
  brew install ollama
  ollama serve              # or: brew services start ollama
  ollama pull gemma3:4b     # 4B/12B/27B are multimodal; 1B is text-only
  ```

## Build & run

```bash
./build.sh
open ShakeSight.app
```

A 👁 icon appears in the menu bar. **Shake the mouse** (several quick
left-right wiggles) anywhere, or use the menu's *Analyze screen now*.

### First-run permissions

macOS will prompt for **Screen Recording** the first time it captures
(System Settings → Privacy & Security → Screen Recording → enable ShakeSight,
then relaunch). Mouse-move observation needs no special permission.

For logs during a demo, run the binary directly instead of `open`:
```bash
./ShakeSight.app/Contents/MacOS/ShakeSight
```

## How it works

| Piece | File | Notes |
|-------|------|-------|
| Shake gesture | `ShakeDetector.swift` | Global `NSEvent` monitor; counts rapid horizontal direction reversals within 0.6s |
| Screen grab | `ScreenCapture.swift` | ScreenCaptureKit `SCScreenshotManager`, display under the cursor |
| Vision model | `OllamaClient.swift` | POSTs base64 PNG to `127.0.0.1:11434/api/generate` |
| Overlay UI | `OverlayController.swift` | Floating non-activating `NSPanel` near the cursor |
| Wiring | `main.swift` | Menu-bar agent (`LSUIElement`), status item, shake → capture → analyze |

## Tuning the shake

In `ShakeDetector.swift`: `reversalsToTrigger`, `windowSeconds`, `minSpeed`,
`cooldown`. Lower the reversal count if it feels too hard to trigger.
