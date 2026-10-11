# Development

## Build

```bash
./scripts/build.sh            # builds build/Yubisashi.app
./scripts/build.sh --install  # also copies it to ~/Applications and launches it
```

The script signs with your "Apple Development" certificate if you have one, so macOS keeps the microphone / screen recording permissions across rebuilds. Without one it signs ad hoc, and you will be asked again after each rebuild.

Regenerate the app icon (`Resources/AppIcon.icns`):

```bash
swift scripts/make_icon.swift
```

## How a recording is analyzed

`Sources/Yubisashi/Analyzer.swift`

- **Segments**: split at pauses (over 1 s, or over 0.8 s after a sentence). Silent stretches become segments only if something happened (a click, a screen change, a long stop).
- **Stop**: the cursor stays within 8 pt for 0.35 s (`Analyzer.dwellRadius`, `dwellMinDuration`). The live overlay uses the same values.
- **Linking a word to a spot**: for each "this" / "here" / これ / ここ…, look for a stop or click from 0.7 s before to 0.9 s after the word. Otherwise use a circle around the time of the word, an area ("around here", 小さな往復), or where the cursor was if it was moving slowly.
- **Motion between spots**: barely moved / fast move / moved / traced slowly / circled / back and forth.

Speech is transcribed on-device with `SpeechAnalyzer`. In Auto mode both Japanese and English are transcribed and the one with higher confidence wins.

## Developer commands

All run from the built binary, e.g. `.build/release/Yubisashi --demo /tmp/out`.

| Command | What it does |
|---|---|
| `--demo <dir>` | End-to-end check with a synthetic screen, voice (`say`) and cursor |
| `--reanalyze <timeline.json> [--retranscribe]` | Re-run the analysis on a saved recording |
| `--eval-materials <dir>` | Build the benchmark materials (`<dir>/<task>/A` and `B`) |
| `--caption-test <wav>` | Feed an audio file to the live caption instead of the microphone |
| `--overlay-preview` | Show the recording overlay for ~9 s without recording |
| `--overlay-snapshot <dir>` | Render the overlay and pill to images |
| `--real-demo-prepare <dir>` / `--real-demo <dir>` | Demo video from a real web page (`<dir>/app`) and a real agent fix |
| `--concept-video <dir> [ja\|en]` | Older concept video |

### Demo video from a real page

1. Put a small web page in `<dir>/app` (tracked with git) and a `<dir>/scenario.json` (what to say, what to point at).
2. `--real-demo-prepare <dir>` photographs the page with WebKit and writes `<dir>/review/review.md`.
3. Paste that review into Claude Code in `<dir>/app` and let it make the change. Save its reply to `agent-output.md`, its steps to `agent-steps.txt`, and `git -C app diff` to `diff.txt`. Optionally save the reply to the same words plus a plain screenshot to `screenshot-reply.md`.
4. `--real-demo <dir>` photographs the fixed page and renders `<dir>/yubisashi-demo.mp4`.

Only the voice (synthetic) and the cursor (scripted) are not real.
