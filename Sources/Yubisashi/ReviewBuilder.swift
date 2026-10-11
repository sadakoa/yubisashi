import CoreGraphics
import Foundation

/// 生データから、エージェントに渡すレビュー記録（review.md・画像・timeline.json）を作る
enum ReviewBuilder {
    struct Output {
        var dir: URL
        var markdownURL: URL
        var markdown: String
        var transcriptionNote: String?
        var segments: [Segment]
        var framesDir: URL
    }

    static func build(from recorded: RecordingData) async -> Output {
        var data = recorded
        // 1. 書き起こし（記録開始からの秒に揃える）
        var chars: [CharStamp] = []
        var note: String?
        do {
            let transcript =
                data.detectSpeechLanguage
                ? try await Transcriber.transcribeAuto(url: data.audioURL)
                : try await Transcriber.transcribeDetailed(url: data.audioURL, language: data.speechLanguage)
            data.speechLanguage = transcript.language
            if data.detectSpeechLanguage, !transcript.stamps.isEmpty { L.rememberSpeech(transcript.language) }
            chars = transcript.stamps.map {
                CharStamp(ch: $0.ch, start: $0.start + data.audioOffset, end: $0.end + data.audioOffset)
            }
            if chars.isEmpty { note = L.s("声が聞き取れませんでした。", "No speech was recognized.") }
        } catch {
            note = L.s("書き起こしに失敗しました: ", "Transcription failed: ") + error.localizedDescription
        }

        // 2. 解析
        let analyzer = Analyzer(data: data, chars: chars)
        var segments = analyzer.run()

        // 3. 画像を描き、指した位置の色を拾う
        let framesDir = data.dir.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let renderer = Renderer(scale: data.pixelScale)
        var cache: [String: CGImage] = [:]
        func image(_ file: String?) -> CGImage? {
            guard let file else { return nil }
            if let hit = cache[file] { return hit }
            let img = loadImage(data.rawFramesDir.appendingPathComponent(file))
            cache[file] = img
            return img
        }

        for si in segments.indices {
            let seg = segments[si]
            for ai in seg.anchors.indices {
                let a = seg.anchors[ai]
                if let img = image(analyzer.frame(atOrBefore: a.t + 0.1)?.file),
                    let c = sampleColors(img, x: a.x * data.pixelScale, y: a.y * data.pixelScale)
                {
                    segments[si].anchors[ai].color =
                        colorsDiffer(c.point, c.around)
                        ? c.point + L.s("（周辺 \(c.around)）", " (around \(c.around))") : c.point
                }
            }
            // 軌跡を描かない元の画面を拡大した、番号ごとのクローズアップ（区間ごとに1枚にまとめる）
            let tiles = segments[si].anchors.compactMap { a in
                image(analyzer.frame(atOrBefore: a.t + 0.1)?.file).flatMap { renderer.closeUp(base: $0, anchor: a) }
            }
            if !tiles.isEmpty {
                let name = String(format: "%02d-closeups.jpg", seg.index)
                renderer.closeUpSheet(tiles, to: framesDir.appendingPathComponent(name))
                for ai in segments[si].anchors.indices { segments[si].anchors[ai].closeUp = name }
            }
            for pi in seg.parts.indices {
                let part = seg.parts[pi]
                let suffix = seg.parts.count > 1 ? String(UnicodeScalar(UInt8(97 + pi))) : ""
                let name = String(format: "%02d%@.jpg", seg.index, suffix)
                segments[si].parts[pi].imageName = name
                guard let base = image(part.frameFile) else { continue }
                var label = "\(seg.index)\(suffix)  \(formatTime(part.start))–\(formatTime(part.end))"
                if let next = part.endsWith { label += "  → \(next.label)" }
                renderer.render(
                    base: base,
                    samples: data.cursor.filter { $0.t >= part.start && $0.t <= part.end },
                    start: part.start, end: part.end,
                    anchors: segments[si].anchors.filter { $0.partIndex == pi },
                    clicks: data.clicks.filter { c in
                        c.t >= part.start && c.t <= part.end
                            && !segments[si].anchors.contains { $0.clickButton != nil && abs($0.x - c.x) < 15 && abs($0.y - c.y) < 15 }
                    },
                    label: label,
                    to: framesDir.appendingPathComponent(name))
            }
        }

        // 4. 書き出し
        let markdown = writeMarkdown(data: data, segments: segments, framesDir: framesDir, note: note)
        let mdURL = data.dir.appendingPathComponent("review.md")
        try? markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        writeTimeline(data: data, chars: chars, segments: segments)
        try? FileManager.default.removeItem(at: data.rawFramesDir)

        return Output(
            dir: data.dir, markdownURL: mdURL, markdown: markdown, transcriptionNote: note, segments: segments,
            framesDir: framesDir)
    }

    // MARK: review.md

    /// 画像は Mac 上のファイルの場所で示す。手元のファイルを読めるエージェント（Claude Code・Codex・Cursor など）向け
    private static func writeMarkdown(data: RecordingData, segments: [Segment], framesDir: URL, note: String?) -> String {
        func imageRef(_ name: String) -> String { framesDir.appendingPathComponent(name).path }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let s = data.pixelScale
        let total = Int(data.duration.rounded())
        let length =
            total >= 60
            ? L.s("\(total / 60)分\(total % 60)秒", "\(total / 60) min \(total % 60) s") : L.s("\(total)秒", "\(total) s")

        // 冒頭は最小限にする。軌跡の色・クローズアップ・発話のない区間などの説明は、画像の凡例と各区間の注記にある
        var md = L.s(
            """
            # 指差しレビュー記録 \(fmt.string(from: data.startDate))（\(length)）

            > **エージェントへ**：画面を見ながら話した改善指示の記録です。発話の中の①②は、直前の「これ」「ここ」などが、画像の同じ番号の位置（番号から伸びた線の先の点）を指していることを表します。対象が見えにくいときは、区間ごとのクローズアップを見てください。書き起こしには誤りが含まれることがあります。どの要素を指しているか確信が持てないときは、推測せずに質問してください。

            - 記録フォルダ: `\(data.dir.path)`
            - 画面: \(Int(data.displaySize.width))×\(Int(data.displaySize.height))pt（画像は \(Int(data.frameSize.width))×\(Int(data.frameSize.height))px、位置は画像の左上からのピクセル）

            """,
            """
            # Yubisashi review \(fmt.string(from: data.startDate)) (\(length))

            > **To the agent**: These are improvement instructions spoken while looking at the screen. A number like ① in the transcript means the word just before it ("this", "here", etc.) refers to the spot with the same number in the image (the dot at the end of the line from the numbered badge). If a target is hard to see, check the segment's close-ups. The transcript may contain recognition errors. If you are not sure which element is meant, ask instead of guessing.

            - Folder: `\(data.dir.path)`
            - Screen: \(Int(data.displaySize.width))×\(Int(data.displaySize.height)) pt (images are \(Int(data.frameSize.width))×\(Int(data.frameSize.height)) px; positions are pixels from the image's top-left)

            """)
        // 要素の情報が取れたときだけ、その読み方を書く（ないときに「ない」と気にさせないため）
        if segments.contains(where: { $0.anchors.contains { $0.element != nil } }) {
            md += L.s(
                "- 「指した要素」は、その位置にあった UI 要素の情報です（種類・名前・DOM の id と class・大きさ）。コードの中で対象を探す手がかりにしてください。\n",
                "- \"Pointed elements\" describe the UI element at that spot (role, name, DOM id and classes, size). Use them to find the target in the code.\n")
        }
        if let video = data.videoURL { md += L.s("- 動画（人が見返す用）", "- Video (for people)") + ": `\(video.path)`\n" }
        if let note { md += L.s("- 注意", "- Note") + ": \(note)\n" }

        for seg in segments {
            md += "\n## \(seg.index). \(formatTime(seg.start))–\(formatTime(seg.end))\n\n"
            for part in seg.parts where part.frameFile != nil {
                let label = part.imageName.replacingOccurrences(of: ".jpg", with: "")
                md += "![\(L.s("区間", "Segment "))\(label)](\(imageRef(part.imageName)))\n"
            }
            md += "\n"
            md +=
                seg.speech
                ? "> \(seg.markedText)\n"
                : L.s("> （発話なし。指示ではなく操作の途中の可能性があります）\n", "> (No speech. This may be navigation rather than an instruction.)\n")

            if !seg.anchors.isEmpty {
                md += L.s(
                    "\n| 番号 | 時刻 | 動き | 画像 | 位置 (px) | 色 | 指示語 |\n|---|---|---|---|---|---|---|\n",
                    "\n| # | Time | Motion | Image | Position (px) | Color | Word |\n|---|---|---|---|---|---|---|\n")
                for a in seg.anchors {
                    let image =
                        seg.parts.indices.contains(a.partIndex)
                        ? seg.parts[a.partIndex].imageName.replacingOccurrences(of: ".jpg", with: "") : ""
                    let words = a.words.isEmpty ? "—" : a.words.map { L.s("「\($0)」", "\"\($0)\"") }.joined(separator: " ")
                    md +=
                        "| \(circled(a.number)) | \(formatTime(a.t)) | \(motionLabel(a, scale: s)) | \(image) | \(Int(a.x * s)), \(Int(a.y * s)) | \(a.color ?? "—") | \(words) |\n"
                }
                // 指した UI 要素（アクセシビリティから取れたときだけ）
                let elements = seg.anchors.compactMap { a in a.element.map { "\(circled(a.number)) \(elementLabel($0, scale: s))" } }
                if !elements.isEmpty {
                    md += "\n" + L.s("指した要素:", "Pointed elements:") + "\n" + elements.map { "- \($0)" }.joined(separator: "\n") + "\n"
                }
                if let sheet = seg.anchors.first?.closeUp {
                    md += "\n" + L.s("クローズアップ（軌跡なしの元の画面。番号は左上、指した位置は角かっこの中心）:", "Close-ups (original screen, no path; number at top-left, the spot is the center of the brackets):") + "\n"
                    md += "![\(L.s("クローズアップ", "Close-ups"))](\(imageRef(sheet)))\n"
                }
            }

            var notes: [String] = []
            for m in seg.moves {
                let detail = String(format: L.s("%dpx・%.1f秒", "%d px, %.1f s"), Int(m.length * s), m.duration)
                if m.from == 0 {
                    notes.append(L.s("区間全体: \(m.kind.label)（\(detail)）", "Whole segment: \(m.kind.label) (\(detail))"))
                } else {
                    var text = "\(circled(m.from))→\(circled(m.to)) " + L.s("\(m.kind.label)（\(detail)）", "\(m.kind.label) (\(detail))")
                    if let c = m.crosses { text += L.s("、途中で\(c.label)", ", \(c.label) on the way") }
                    notes.append(text)
                }
            }
            for e in seg.events { notes.append("\(formatTime(e.t)) \(e.kind.label)") }
            if seg.scrolled, !seg.events.contains(where: { $0.kind == .scroll }) { notes.append(L.s("スクロールあり", "Scrolled")) }
            if !notes.isEmpty {
                md += "\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
        }

        return md
    }

    /// 「Button「保存」 #save .btn.primary 120×44pt — Safari」のような1行
    static func elementLabel(_ e: ElementInfo, scale s: Double) -> String {
        var parts: [String] = []
        let role = (e.role ?? "").replacingOccurrences(of: "AX", with: "")
        if let label = e.label { parts.append(L.s("\(role)「\(label)」", "\(role) \"\(label)\"")) } else if !role.isEmpty { parts.append(role) }
        if let text = e.text { parts.append(L.s("中の文字「\(text)」", "text \"\(text)\"")) }
        if let id = e.domId { parts.append("#\(id)") }
        if let classes = e.domClasses { parts.append(classes.map { ".\($0)" }.joined()) }
        if let f = e.frame, f.count == 4 { parts.append("\(Int(f[2]))×\(Int(f[3]))pt") }
        if let path = e.ancestors { parts.append(L.s("場所: ", "in: ") + path.joined(separator: " > ")) }
        var line = parts.joined(separator: " · ")
        if let app = e.app { line += " — \(app)" }
        if let url = e.url { line += " (\(url))" }
        return line
    }

    static func clickLabel(_ button: String?) -> String {
        button == "right" ? L.s("右クリック", "right-click") : L.s("クリック", "click")
    }

    static func motionLabel(_ a: Anchor, scale s: Double) -> String {
        var motion: String
        switch a.kind {
        case .dwell: motion = String(format: L.s("止まる %.1f秒", "stopped %.1f s"), a.dwellDuration)
        case .click: motion = clickLabel(a.clickButton)
        case .circle: motion = L.s("囲む（半径 \(Int(a.radius * s))px）", "circled (radius \(Int(a.radius * s)) px)")
        case .area: motion = L.s("範囲を示す（半径 \(Int(a.radius * s))px）", "area (radius \(Int(a.radius * s)) px)")
        case .pass: motion = L.s("ゆっくり通過", "passed slowly")
        }
        if a.kind == .dwell, a.clickButton != nil { motion += L.s("＋", " + ") + clickLabel(a.clickButton) }
        return motion
    }

    // MARK: timeline.json

    private struct Timeline: Encodable {
        var version = 2
        var speechLanguage: Lang
        var startDate: Date
        var duration: Double
        var displaySize: [Double]
        var frameSize: [Double]
        var pixelScale: Double
        var audioOffset: Double
        var transcript: [CharStamp]
        var cursor: [CursorSample]
        var clicks: [ClickEvent]
        var scrolls: [Double]
        var transitions: [Double]
        var segments: [Segment]
        var probes: [ElementProbeRecord]
    }

    private static func writeTimeline(data: RecordingData, chars: [CharStamp], segments: [Segment]) {
        let round3 = { (v: Double) in (v * 1000).rounded() / 1000 }
        let timeline = Timeline(
            speechLanguage: data.speechLanguage, startDate: data.startDate, duration: round3(data.duration),
            displaySize: [data.displaySize.width, data.displaySize.height],
            frameSize: [data.frameSize.width, data.frameSize.height],
            pixelScale: data.pixelScale, audioOffset: round3(data.audioOffset),
            transcript: chars.map { CharStamp(ch: $0.ch, start: round3($0.start), end: round3($0.end)) },
            cursor: data.cursor.map { CursorSample(t: round3($0.t), x: round3($0.x), y: round3($0.y), on: $0.on) },
            clicks: data.clicks, scrolls: data.scrolls.map(round3), transitions: data.transitions.map(round3),
            segments: segments, probes: data.probes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let json = try? encoder.encode(timeline) {
            try? json.write(to: data.dir.appendingPathComponent("timeline.json"))
        }
    }
}
