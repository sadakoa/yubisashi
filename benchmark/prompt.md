# Prompt given to the agents

Every condition got the same instructions; only the “Materials” part differed. The correct answers were not given.

The prompt was written in Japanese, as below. An English translation follows.

## Original (Japanese)

```
あなたはコーディングエージェントです。ユーザー（デザイナー）から、画面の改善指示を受け取りました。次の資料だけを読んでください。ほかのファイルやフォルダは開かないでください。ファイルの作成や編集もしないでください。

資料:
（条件ごとの資料）

やること: 指示を、開発者がそのまま作業できる改善項目の一覧にしてください。項目ごとに次を書いてください。
- 対象: どの要素か。画面上の位置や周りの文字を使って、ほかの要素と取り違えないように具体的に
- 問題
- 期待する変更
- 確信度: 高 / 中 / 低（対象を特定できた自信）
対象を特定できない場合は、推測した候補と、ユーザーに確認したい質問を書いてください。

回答だけを返してください。
```

## English translation

```
You are a coding agent. A user (a designer) sent you improvement notes about a screen. Read only the materials below. Do not open other files or folders. Do not create or edit files.

Materials:
(materials for the condition)

Task: turn the notes into a list of improvements a developer can work from. For each item, write:
- Target: which element. Be specific, using its position on screen and nearby text, so it can't be confused with another element
- Problem
- Expected change
- Confidence: high / medium / low (how sure you are about the target)
If you can't identify the target, list your best guesses and the question you'd ask the user.

Return only your answer.
```

## Materials per condition

**A: Screenshot + text**

```
- Screenshot: <materials>/<task>/A/screen-1.jpg (the buttons task also has screen-2.jpg, in the order of the steps)
- What the user said (dictation transcript): <materials>/<task>/A/instruction.txt
```

**Yubisashi (each version)**

```
- The user's recording: <materials>/<task>/B/review.md (you may also read the images and files it references)
```
