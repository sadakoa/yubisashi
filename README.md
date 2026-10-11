<p align="center">
  <img src="docs/icon.png" width="112" alt="Yubisashi icon">
</p>

<h1 align="center">Yubisashi</h1>

<p align="center">
  Point at your screen, say what you want, and paste it into your coding agent.<br>
  <sub><i>Yubisashi</i> (指差し) means “pointing” in Japanese.</sub>
</p>

<p align="center">
  <img src="docs/demo.gif" width="860" alt="With a plain screenshot, Claude can't tell what “move this up here” means. With Yubisashi, it moves the Download CSV link next to the Share button.">
</p>

## Why

“Move this up here” is easy to say and hard to type. A screenshot can’t tell your agent *which* element you mean or *where* it should go.

Yubisashi records your voice and your cursor together, and links every “this” and “here” to the spot you pointed at.

## How it works

1. Press **⌃⌥R** and talk while you point.
2. Press **⌃⌥R** again. A `review.md` with annotated screenshots is copied to your clipboard.
3. Paste it into Claude Code, Codex, Cursor, or any coding agent that can read local files.

What the agent receives:

<p align="center">
  <img src="docs/review-example.jpg" width="760" alt="Annotated screenshot: ① on the Download CSV link, a pink path up to ② next to the Share button">
</p>

> Move this①. Up here②.

Each number in the transcript points to the same number in the image. The pink line is the cursor path, light to dark over time.

## Results

Same screen, same words, two ways of handing them to Claude Code:

| | “this” / “here” resolved | Asked which element | Tokens | Time |
|---|---|---|---|---|
| Screenshot + text | 67% (18/27) | 17 times | 61k | 82 s |
| **Yubisashi** | **100% (27/27)** | **0 times** | 64k | 60 s |

A small benchmark: 2 synthetic UI tasks, 6 runs each. The prompts, scoring and every raw answer are in [benchmark/](benchmark/).

## Install

There is no prebuilt app yet, so you build it yourself. You need **macOS 26** and **Xcode 26**.

1. **Download** the code with git, or use **Code → Download ZIP** on this page and unzip it.

   ```bash
   git clone https://github.com/sadakoa/yubisashi
   cd yubisashi
   ```

2. **Build and install.** This puts `Yubisashi.app` in `~/Applications` and starts it. Its icon appears in the menu bar.

   ```bash
   ./scripts/build.sh --install
   ```

3. **Allow permissions** when macOS asks: **Microphone** and **Screen & System Audio Recording**. Then quit Yubisashi from the menu bar and open it again.

On first launch, macOS also downloads the on-device speech models. **Settings → Speech model** shows when they’re ready.

**Accessibility** is optional (**Settings → Capture Element Info…**). It adds the pointed element’s name, DOM id/classes and page URL to the review.

## Usage

1. Open what you want to change: your app, a web page, a design.
2. Press **⌃⌥R** (Control-Option-R). A pill appears at the bottom of the screen, and a pink trail follows your cursor.
3. **Point and talk.** Rest the cursor on a spot for a moment as you say “this” or “here”, or circle an area for “around here”. Your words appear as live captions.
4. Press **⌃⌥R** again, or **Stop** in the pill. After a few seconds, the review is copied.
5. Paste it (⌘V) into Claude Code in your project and send.

Changed your mind? Click **Discard** in the pill.

From the menu bar:

- **Copy Latest Review** copies the last review again.
- **Settings**: UI language (English / 日本語), speech language (Auto / English / 日本語), open at login.

## Privacy

- **Nothing leaves your Mac.** Recording and transcription run on-device; there is no network code.
- **Only the latest recording is kept**, in `~/Library/Caches/Yubisashi/`, readable only by you.
- **No keystrokes are recorded.** Text in input and password fields is never read.
- **What you paste is what the agent sees**: the images, the transcript and the folder path.

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

MIT
