# Benchmark: screenshot + text vs Yubisashi

How well does a coding agent understand improvement notes like “make **this** match **that**” when it gets them as a plain screenshot and text, versus as a Yubisashi recording?

## Results

| Condition | Runs | “this” / “here” resolved | Asked which element | Tokens (avg) | Time (avg) |
|---|---|---|---|---|---|
| A: Screenshot + text | 6 | 18/27 (67%) | 17/27 | 61.3k | 82.3 s |
| **Yubisashi v0.3** | 6 | **27/27 (100%)** | **0/27** | 64.3k (+5%) | 60.1 s (−27%) |

- **Resolved**: the agent identified the element that “this”, “that”, “here” referred to.
- **Asked which element**: the agent asked the user to confirm what a word referred to. Each one is an extra round trip.
- Tokens and time are per agent run (reading, reasoning and answering).

### By task

| Task | Condition | Resolved | Asked | Tokens | Time |
|---|---|---|---|---|---|
| Buttons (4 words) | A | 6/12 (50%) | 9/12 | 56.7k | 37.7 s |
| | Yubisashi v0.3 | 12/12 (100%) | 0/12 | 61.7k | 49.0 s |
| Dashboard (5 words) | A | 12/15 (80%) | 8/15 | 65.8k | 126.9 s |
| | Yubisashi v0.3 | 15/15 (100%) | 0/15 | 66.8k | 71.3 s |

### What we learned

- **Yubisashi helps most when the screen alone can’t answer the question.**
  - “Make this button’s color match that one”: with a screenshot, the agent could not tell which button should change, all 3 times.
  - “Make this label a bit darker”: four labels look identical, and the agent could not tell which one, all 3 times.
- **Screenshots do fine with visible inconsistencies.** A bigger icon, a tighter gap or a wider padding were found by measuring pixels.
- **Time depends on the task.** On the simple task Yubisashi was slower (+30%, more images to read). On the harder one it was faster (−44%), because the agent no longer had to measure pixels to guess.
- Questions that remained in both conditions (“only this label, or all four?”, “where should the back button go?”) are about scope or destination that the speech itself left open. Asking is the right behavior there.

## Version history

| Version | Change | Runs | Resolved | Tokens | Time |
|---|---|---|---|---|---|
| v0.1 | First version | 4 | 18/18 (100%) | 75.8k | 107.2 s |
| v0.2 | Per-spot close-ups without the path drawn; better segment splitting; no pointer to the raw `timeline.json` | 4 | 18/18 (100%) | 67.2k | 66.2 s |
| v0.3 | Minimal agent instructions at the top (review.md about 40% shorter) | 6 | 27/27 (100%) | 64.3k | 60.1 s |

In v0.1 agents sometimes opened the thousands-of-lines raw data, and the path and badges covered the text they pointed at, which cost tokens and time.

## Method

### Tasks

Synthetic screens and synthetic speech (macOS `say -v Kyoko`, Japanese). The cursor movement is generated from the times the pointing words are spoken in the transcript, then run through Yubisashi’s own analysis and export.

**Buttons** (2 screens, 2 sentences)

> このボタンの色、こっちと揃えたい。それから、ここを押すと詳細に行くけど、戻るボタンがこのあたりにあるのは遠い。
> *“I want this button’s color to match this one. Then, when I press here it opens the details, but the back button being around here is too far.”*

| Word | Correct element |
|---|---|
| この (this button) | The “Save” button on the list screen |
| こっち (this one) | The “Cancel” button (Save should match Cancel) |
| ここ (here) | The “Pricing page” card on the right (pressed to open the details) |
| この (around here) | “‹ Back” on the details screen |

**Dashboard** (1 screen, 4 sentences)

> この余白、こっちと同じにして。このアイコンだけ、少し大きい。このラベル、もう少し濃くしたい。タグの並び、ここだけ詰まってる。
> *“Make this padding the same as this one. Only this icon is a bit bigger. I want this label a bit darker. In the tags, only here is too tight.”*

| Word | Correct element |
|---|---|
| この (this padding) | Left inner padding of the 2nd card, “Conversion” |
| こっち (this one) | Left inner padding of the 1st card, “Visitors” |
| この (this icon) | The bell, among six header icons |
| この (this label) | The “Avg. time” label on the 3rd card (all four labels look the same) |
| ここ (here) | Between the “Repeat” and “Mobile” tags |

The icon size, the padding and the tag gap are visibly inconsistent on screen. The label color is not: nothing on screen tells which label is meant.

### Conditions

- **A: Screenshot + text** — screenshots without any marks, plus the transcript (like dictation + a screenshot).
- **Yubisashi** — the `review.md` and images that Yubisashi exports.

The agent was a Claude Code general-purpose subagent (Claude Opus 5.5), started separately for every run. All runs got the same instructions; only the materials differed. See [prompt.md](prompt.md).

### Scoring

- **Resolved**: the agent’s main answer names the right element (regardless of the stated confidence).
- **Not resolved**: the agent only listed candidates, asked without choosing, or named a different element.
- **In favor of A**: answering “this one” as “the other three cards” counted as correct, because the fix ends up the same. “Back button” is named in the speech, so A got it right too.
- **Asked which element**: counted per word the agent asked the user to confirm, whether or not its guess was right. Questions about scope or degree (“only this one or all four?”) were not counted.

Per-run numbers are in [results.csv](results.csv). Every agent answer is in [runs/](runs/) (in Japanese, as the prompt was). The materials given to the agents are in [materials/](materials/) (A and v0.3; file locations replaced with `<materials>`).

## Limitations

- Two synthetic screens and few runs: 6 per condition (4 for v0.1 and v0.2).
- The voice was synthetic and transcribed almost perfectly. Real speech will have more recognition errors.
- The tasks were designed and scored by the author. The correct answers are fixed by the script, but the choice of tasks may be biased.
- In A, the text is the raw transcript. Rewriting it carefully would raise A’s score, but that effort was not measured.
- Tokens include the agent’s fixed overhead (instructions and tool descriptions). The difference between conditions mostly comes from the materials (number of images).
- Runs for v0.1 / v0.2 and some runs for A / v0.3 were made on different days, with the same prompt and the same A materials.

## Reproduce

```bash
swift build -c release
.build/release/Yubisashi --eval-materials eval   # builds eval/<task>/A and eval/<task>/B
```

Give `eval/<task>/A` and `eval/<task>/B` to an agent with the prompt in [prompt.md](prompt.md), and score with the tables above.
