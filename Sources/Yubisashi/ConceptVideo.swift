import AVFoundation
import AppKit
import CoreText

/// コンセプト動画を作る。`Yubisashi --concept-video <出力先フォルダ> [ja|en]`
///
/// 合成音声（say）で指示を読み上げ、その書き起こしの時刻に合わせてカーソルを動かす。
/// 記録中の表示と、書き出される画像・記録は、アプリと同じ描画と書き出し処理で作る。
enum ConceptVideo {
    static let size = CGSize(width: 1920, height: 1080)
    static let fps = 30.0

    // MARK: 台本

    struct Script {
        var voice: String
        var lineA: String
        var lineB: String
        /// 書き起こしの中で探す指示語（順番どおり）。保存ボタン・キャンセル・カード・戻るボタンに対応する
        var words: [String]
        var title: String
        var tagline: String
        var problem: String
        var solution: String
        var outputTitle: String
        var outputNote: String
        var agentTitle: String
        var agentPasted: (Int, Int) -> String
        var agentReply: (String) -> String
        var agentLabel: String
        var endSteps: String
        var keyStart: String
        var keyStop: String
        var appTitle: String
        var heading: String
        var save: String
        var cancel: String
        var cards: [String]
        var cardMeta: String
        var activity: String
        var rows: [String]
        var back: String
        var detailBody: [String]
    }

    static func script(_ lang: Lang) -> Script {
        if lang == .ja {
            return Script(
                voice: "Kyoko",
                lineA: "このボタンの色、こっちと揃えたい。",
                lineB: "それから、ここを押すと詳細に行くけど、戻るボタンがこのあたりにあるのは遠い。",
                words: ["この", "こっち", "ここ", "この"],
                title: "Yubisashi",
                tagline: "指差して、話すだけ。",
                problem: "スクリーンショットと文章では、「これ」「ここ」がどこなのか伝わらない。",
                solution: "Yubisashi は、話した言葉とカーソルの動きを、時刻で結びつけて渡します。",
                outputTitle: "書き出される記録",
                outputNote: "review.md はクリップボードにコピー済み。エージェントに貼るだけ。",
                agentTitle: "エージェントに貼ると",
                agentPasted: { segs, imgs in "[貼り付け] review.md — \(segs)区間・画像\(imgs)枚" },
                agentReply: { color in
                    """
                    改善項目（2件）

                    1. 保存ボタンの色をキャンセルボタンに揃える
                       対象: 保存ボタン（区間1 ①）
                       期待: キャンセルと同じ \(color)

                    2. 詳細画面の戻るボタンを押しやすい位置へ
                       対象: 戻るボタン（区間2 ②）
                       問題: 開いたカード（区間2 ①）から遠い

                    確認: 揃えるのは背景色だけですか？ 文字色も含めますか？
                    """
                },
                agentLabel: "返答の例（イメージ）",
                endSteps: "⌃⌥R で記録  →  指して話す  →  貼るだけ",
                keyStart: "記録開始", keyStop: "終了",
                appTitle: "プロジェクト", heading: "プロジェクト", save: "保存", cancel: "キャンセル",
                cards: ["Q4 リニューアル", "オンボーディング改善", "料金ページ"], cardMeta: "最終更新 10月8日",
                activity: "最近の更新",
                rows: ["料金ページ のコピーを更新しました", "オンボーディング改善 にコメントが2件", "Q4 リニューアル の画面を追加しました", "デザインレビューを予約しました"],
                back: "‹ 戻る",
                detailBody: ["料金表の見せ方を見直す。", "プランごとの違いを、ひと目で比べられるようにする。"])
        }
        return Script(
            voice: "Samantha",
            lineA: "Make this button's color match that one.",
            lineB: "Then when I click here, it opens the details, but the back button up around here is too far.",
            words: ["this", "that", "here", "here"],
            title: "Yubisashi",
            tagline: "Point and talk.",
            problem: "Screenshots and text can't show which \"this\" or \"here\" you mean.",
            solution: "Yubisashi links each word you say to where your cursor was at that moment.",
            outputTitle: "What gets exported",
            outputNote: "review.md is already on your clipboard. Just paste it into your agent.",
            agentTitle: "Paste it into your agent",
            agentPasted: { segs, imgs in "[pasted] review.md — \(segs) segments, \(imgs) images" },
            agentReply: { color in
                """
                Improvements (2)

                1. Match the Save button color to Cancel
                   Target: Save button (segment 1 ①)
                   Expected: same as Cancel, \(color)

                2. Move the Back button on the details screen closer
                   Target: Back button (segment 2 ②)
                   Problem: far from the card you opened (segment 2 ①)

                Question: should only the background color match, or the text color too?
                """
            },
            agentLabel: "Example reply (illustrative)",
            endSteps: "⌃⌥R to record  →  point and talk  →  paste",
            keyStart: "Start", keyStop: "Stop",
            appTitle: "Projects", heading: "Projects", save: "Save", cancel: "Cancel",
            cards: ["Q4 Redesign", "Onboarding", "Pricing page"], cardMeta: "Updated Oct 8",
            activity: "Recent activity",
            rows: ["Updated copy on Pricing page", "2 new comments on Onboarding", "Added screens to Q4 Redesign", "Design review scheduled"],
            back: "‹ Back",
            detailBody: ["Rethink how the pricing table is shown.", "Make the differences between plans easy to compare."])
    }

    // 画面上の位置（左上原点、ポイント = ピクセル）
    static let window = CGRect(x: 260, y: 70, width: 1400, height: 810)
    static let saveRect = CGRect(x: 1450, y: 148, width: 160, height: 46)
    static let cancelRect = CGRect(x: 1270, y: 148, width: 160, height: 46)
    static let cardRects = [320.0, 760.0, 1200.0].map { CGRect(x: $0, y: 240, width: 400, height: 230) }
    static let backCenter = CGPoint(x: 336, y: 158)

    // MARK: 実行

    /// 台本どおりに「記録」を作り、アプリの書き出し処理を通した結果
    struct Recorded {
        var output: ReviewBuilder.Output
        var screenList: CGImage
        var screenDetail: CGImage
        var choreo: Choreo
        var levels: [Double]
        var chars: [CharStamp]
        var voiceURL: URL
        var duration: Double
    }

    static func record(work: URL, lang: Lang, reviewDir: URL? = nil) async throws -> Recorded {
        L.override = lang
        L.speechOverride = lang
        let sc = script(lang)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. 声: 2つの文を読み上げ、間を空けて1本にする
        let a = try say(sc.lineA, voice: sc.voice, to: work.appendingPathComponent("a.wav"))
        let b = try say(sc.lineB, voice: sc.voice, to: work.appendingPathComponent("b.wav"))
        // 話題の切れ目として、区間が分かれる長さの間を空ける（Analyzer は 1.2 秒以上で区切る）
        let combinedURL = work.appendingPathComponent("voice.wav")
        let samples = try combine([a, b], gaps: [1.0, 1.7, 1.5], to: combinedURL)
        let duration = Double(samples.count) / 16000

        // 2. 書き起こしから指示語の時刻を取る
        let chars = try await Transcriber.transcribe(url: combinedURL, language: lang)
        let times = try wordTimes(sc.words, in: chars, english: lang == .en)

        // 3. カーソルの動きを作る
        let choreo = choreograph(times: times, duration: duration)

        // 4. アプリの書き出し処理で、実際の記録を作る
        let screenList = renderScreen(sc, detail: false)
        let screenDetail = renderScreen(sc, detail: true)
        let output = try await buildReview(
            dir: reviewDir ?? work.appendingPathComponent("review", isDirectory: true),
            screens: [(0, screenList), (choreo.transition, screenDetail)], choreo: choreo,
            voiceURL: combinedURL, duration: duration, lang: lang)
        return Recorded(
            output: output, screenList: screenList, screenDetail: screenDetail, choreo: choreo,
            levels: levelEnvelope(samples), chars: chars, voiceURL: combinedURL, duration: duration)
    }

    /// 画面の絵とカーソルの動きから、アプリと同じ書き出し処理で記録を作る
    static func buildReview(
        dir: URL, screens: [(Double, CGImage)], choreo: Choreo, voiceURL: URL, duration: Double, lang: Lang
    ) async throws -> ReviewBuilder.Output {
        let raw = dir.appendingPathComponent("frames_raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let frameSize = CGSize(width: 1600, height: 900)
        var frames: [FrameRecord] = []
        for (i, screen) in screens.enumerated() {
            let name = String(format: "f%05d.jpg", i + 1)
            writeJPEG(scaled(screen.1, to: frameSize), to: raw.appendingPathComponent(name), quality: 0.92)
            frames.append(FrameRecord(t: screen.0, file: name, change: 1))
        }
        let data = RecordingData(
            dir: dir, rawFramesDir: raw, startDate: Date(), duration: duration,
            displaySize: size, frameSize: frameSize, frames: frames,
            transitions: screens.dropFirst().map(\.0), cursor: choreo.samples,
            clicks: choreo.click.map { [ClickEvent(t: $0, x: choreo.clickPoint.x, y: choreo.clickPoint.y, button: "left")] } ?? [],
            scrolls: [], audioURL: voiceURL, audioOffset: 0, videoURL: nil, speechLanguage: lang)
        return await ReviewBuilder.build(from: data)
    }

    static func run(outputDir: URL, lang: Lang) async throws -> URL {
        let sc = script(lang)
        let work = outputDir.appendingPathComponent("work-\(lang.rawValue)", isDirectory: true)
        let rec = try await record(work: work, lang: lang)

        // 5. 動画の時間割
        var tl = Timeline()
        tl.recStart = 8.3
        tl.recDuration = rec.duration
        let movie = Movie(
            sc: sc, tl: tl, choreo: rec.choreo, levels: rec.levels, chars: rec.chars,
            screenList: rec.screenList, screenDetail: rec.screenDetail, output: rec.output,
            speechSegments: rec.output.segments.filter(\.speech))

        // 6. 映像を書き出し、声と効果音を重ねる
        let silentURL = work.appendingPathComponent("video.mp4")
        try await movie.write(to: silentURL)
        let finalURL = outputDir.appendingPathComponent("yubisashi-concept-\(lang.rawValue).mp4")
        var sounds: [(URL, Double)] = [(rec.voiceURL, tl.recStart)]
        let sys = URL(fileURLWithPath: "/System/Library/Sounds")
        sounds.append((sys.appendingPathComponent("Tink.aiff"), tl.recStart))
        sounds.append((sys.appendingPathComponent("Pop.aiff"), tl.recStop))
        sounds.append((sys.appendingPathComponent("Glass.aiff"), tl.recStop + tl.processing))
        try await mux(video: silentURL, sounds: sounds, to: finalURL)
        return finalURL
    }

    // MARK: 声

    static func say(_ text: String, voice: String, to url: URL) throws -> [Float] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-r", voice == "Kyoko" ? "190" : "175", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// 無音 → 文 → 無音 → 文 → 無音 の順につなぎ、16kHz の WAV に書く
    static func combine(_ parts: [[Float]], gaps: [Double], to url: URL) throws -> [Float] {
        var out: [Float] = []
        for (i, part) in parts.enumerated() {
            out += [Float](repeating: 0, count: Int(gaps[i] * 16000))
            out += part
        }
        out += [Float](repeating: 0, count: Int(gaps[parts.count] * 16000))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(out.count))!
        buffer.frameLength = AVAudioFrameCount(out.count)
        out.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return out
    }

    /// 1/30 秒ごとの声の大きさ（0〜1）。アプリのメーターと同じ換算
    static func levelEnvelope(_ s: [Float]) -> [Double] {
        let hop = Int(16000 / fps)
        var levels: [Double] = []
        var i = 0
        while i < s.count {
            let chunk = s[i..<min(s.count, i + hop)]
            let rms = sqrt(chunk.map { Double($0 * $0) }.reduce(0, +) / Double(max(chunk.count, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            levels.append(max(0, min(1, (db + 50) / 40)))
            i += hop
        }
        // 少しなめらかに
        return levels.indices.map { k in
            let lo = max(0, k - 2)
            let hi = min(levels.count - 1, k + 2)
            return levels[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    static func wordTimes(_ words: [String], in chars: [CharStamp], english: Bool) throws -> [Double] {
        let flat = chars.flatMap { s in Array(s.ch.lowercased()).map { (c: $0, t: s.start) } }
        let cs = flat.map(\.c)
        var times: [Double] = []
        var from = 0
        for w in words {
            let target = Array(w)
            var found: Int?
            var i = from
            while i + target.count <= cs.count {
                if Array(cs[i..<(i + target.count)]) == target,
                    !english || ((i == 0 || !cs[i - 1].isLetter) && (i + target.count == cs.count || !cs[i + target.count].isLetter))
                {
                    found = i
                    break
                }
                i += 1
            }
            guard let found else {
                throw YubisashiError("concept video: '\(w)' not found in transcript: \(String(cs))")
            }
            times.append(flat[found].t)
            from = found + target.count
        }
        return times
    }

    // MARK: カーソルの振り付け

    struct Choreo {
        var samples: [CursorSample]
        var click: Double?
        var clickPoint: CGPoint
        var transition: Double
    }

    private static func choreograph(times t: [Double], duration: Double) -> Choreo {
        let save = CGPoint(x: saveRect.midX + 6, y: saveRect.midY + 2)
        let cancel = CGPoint(x: cancelRect.midX - 4, y: cancelRect.midY + 3)
        let card = CGPoint(x: cardRects[2].midX + 10, y: cardRects[2].midY - 20)
        let click = t[2] + 0.35
        let transition = t[2] + 0.7
        let loopStart = t[3] - 0.5
        let loopDur = 1.5
        let rx = 72.0
        let ry = 30.0

        // (時刻, 位置)。同じ位置が続く所は止まっている
        let keys: [(Double, CGPoint)] = [
            (0, CGPoint(x: 1000, y: 640)),
            (t[0] - 0.4, save), (t[0] + 0.65, save),
            (t[1] - 0.35, cancel), (t[1] + 0.65, cancel),
            (t[2] - 0.45, card), (t[2] + 0.85, card),
            (loopStart, CGPoint(x: backCenter.x + rx, y: backCenter.y)),
        ]

        func position(_ time: Double) -> CGPoint {
            if time >= loopStart {
                let u = min(1, (time - loopStart) / loopDur)
                let a = u * 2 * .pi
                let p = CGPoint(x: backCenter.x + rx * cos(a), y: backCenter.y - ry * sin(a))
                if u < 1 { return p }
                // 囲み終わったら、ボタンの近くに落ち着く
                let rest = min(1, (time - loopStart - loopDur) / 0.6)
                let e = rest * rest * (3 - 2 * rest)
                let settle = CGPoint(x: backCenter.x + 28, y: backCenter.y + 12)
                return CGPoint(x: p.x + (settle.x - p.x) * e, y: p.y + (settle.y - p.y) * e)
            }
            for k in 1..<keys.count where time <= keys[k].0 {
                let (ta, pa) = keys[k - 1]
                let (tb, pb) = keys[k]
                let u = max(0, min(1, (time - ta) / max(tb - ta, 0.01)))
                let e = u * u * (3 - 2 * u)
                let dx = pb.x - pa.x
                let dy = pb.y - pa.y
                let bow = sin(e * .pi) * 0.12
                // 手の動きらしく、少し弧を描く
                var p = CGPoint(x: pa.x + dx * e - dy * bow, y: pa.y + dy * e + dx * bow)
                if pa == pb {
                    // 止まっている間のわずかな手ぶれ（止まる判定の半径より十分小さい）
                    p.x += 1.2 * sin(time * 7.3)
                    p.y += 1.0 * cos(time * 5.1)
                }
                return p
            }
            return keys.last!.1
        }

        var samples: [CursorSample] = []
        var time = 0.0
        while time <= duration {
            let p = position(time)
            samples.append(CursorSample(t: time, x: p.x, y: p.y, on: true))
            time += 1.0 / 60
        }
        return Choreo(samples: samples, click: click, clickPoint: position(click), transition: transition)
    }

    // MARK: 画面（アプリの絵）

    static func renderScreen(_ sc: Script, detail: Bool) -> CGImage {
        let ctx = Draw.context(size)
        Draw.flip(ctx, height: size.height)

        // デスクトップとメニューバー
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [Draw.rgb(0x2B2F4A), Draw.rgb(0x4A3B5C)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        ctx.setFillColor(Draw.white.copy(alpha: 0.16)!)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
        var x = 22.0
        for (i, label) in [sc.appTitle, "File", "Edit", "View"].enumerated() {
            let a = Draw.text(label, 14, i == 0 ? .semibold : .regular, Draw.white)
            Draw.line(ctx, a, x: x, baseline: 20)
            x += Draw.width(a) + 22
        }
        let clock = Draw.text("Fri 10:49", 14, .regular, Draw.white)
        Draw.line(ctx, clock, x: size.width - 22 - Draw.width(clock), baseline: 20)

        // ウインドウ
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 44, color: Draw.black.copy(alpha: 0.4))
        Draw.rrect(ctx, window, 14, fill: Draw.white)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.clip()
        ctx.setFillColor(Draw.rgb(0xF4F4F6))
        ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 52))
        ctx.setFillColor(Draw.rgb(0xE4E4E8))
        ctx.fill(CGRect(x: window.minX, y: window.minY + 52, width: window.width, height: 1))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Draw.rgb(c))
            ctx.fillEllipse(in: CGRect(x: window.minX + 22 + Double(i) * 22, y: window.minY + 19, width: 14, height: 14))
        }
        let title = Draw.text(detail ? sc.cards[2] : sc.appTitle, 15, .semibold, Draw.rgb(0x55555F))
        Draw.line(ctx, title, x: window.midX - Draw.width(title) / 2, baseline: window.minY + 32)

        let ink = Draw.rgb(0x1C1C22)
        let sub = Draw.rgb(0x7A7A85)
        let pastel = [(0xFFD6E8, 0xD9E4FF), (0xD8F5E6, 0xD6ECFF), (0xFFE9C7, 0xFFD2D2)]
        if !detail {
            Draw.line(ctx, Draw.text(sc.heading, 30, .bold, ink), x: 320, baseline: 184)
            Draw.rrect(ctx, cancelRect, 10, fill: Draw.rgb(0x2D6AE9))
            Draw.centered(ctx, Draw.text(sc.cancel, 18, .semibold, Draw.white), center: CGPoint(x: cancelRect.midX, y: cancelRect.midY))
            Draw.rrect(ctx, saveRect, 10, fill: Draw.rgb(0x3B7AFF))
            Draw.centered(ctx, Draw.text(sc.save, 18, .semibold, Draw.white), center: CGPoint(x: saveRect.midX, y: saveRect.midY))
            for (i, r) in cardRects.enumerated() {
                Draw.rrect(ctx, r, 14, fill: Draw.white, stroke: Draw.rgb(0xE2E2E8), lw: 1.5)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil))
                ctx.clip()
                let g = CGGradient(
                    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [Draw.rgb(pastel[i].0), Draw.rgb(pastel[i].1)] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.minY + 130), options: [])
                ctx.restoreGState()
                Draw.line(ctx, Draw.text(sc.cards[i], 21, .bold, ink), x: r.minX + 22, baseline: r.minY + 170)
                Draw.line(ctx, Draw.text(sc.cardMeta, 15, .regular, sub), x: r.minX + 22, baseline: r.minY + 200)
            }
            Draw.line(ctx, Draw.text(sc.activity, 20, .bold, ink), x: 320, baseline: 534)
            for (i, row) in sc.rows.enumerated() {
                let y = 556.0 + Double(i) * 74
                ctx.setFillColor(Draw.rgb([0xC9D8FF, 0xFFD3E6, 0xD3F2E2, 0xFFE6C2][i]))
                ctx.fillEllipse(in: CGRect(x: 320, y: y + 14, width: 42, height: 42))
                Draw.line(ctx, Draw.text(row, 18, .medium, ink), x: 380, baseline: y + 34)
                Draw.line(ctx, Draw.text("\(i + 1)h", 15, .regular, sub), x: 1560, baseline: y + 34)
                Draw.line(ctx, Draw.text(sc.cardMeta, 14, .regular, sub), x: 380, baseline: y + 56)
                ctx.setFillColor(Draw.rgb(0xEEEEF2))
                ctx.fill(CGRect(x: 320, y: y + 70, width: 1290, height: 1))
            }
        } else {
            Draw.line(ctx, Draw.text(sc.back, 21, .medium, Draw.rgb(0x2D6AE9)), x: 300, baseline: 165)
            Draw.line(ctx, Draw.text(sc.cards[2], 32, .bold, ink), x: 560, baseline: 186)
            ctx.saveGState()
            let hero = CGRect(x: 560, y: 220, width: 1040, height: 300)
            ctx.addPath(CGPath(roundedRect: hero, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.clip()
            let g = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                colors: [Draw.rgb(pastel[2].0), Draw.rgb(pastel[2].1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: hero.origin, end: CGPoint(x: hero.maxX, y: hero.maxY), options: [])
            ctx.restoreGState()
            for (i, line) in sc.detailBody.enumerated() {
                Draw.line(ctx, Draw.text(line, 20, .regular, ink), x: 560, baseline: 580 + Double(i) * 38)
            }
            for i in 0..<3 {
                Draw.rrect(ctx, CGRect(x: 560 + Double(i) * 352, y: 680, width: 336, height: 150), 12, fill: Draw.rgb(0xF6F6F9), stroke: Draw.rgb(0xE6E6EC), lw: 1)
            }
            for i in 0..<5 {
                Draw.rrect(ctx, CGRect(x: 300, y: 230 + Double(i) * 46, width: 200, height: 14), 7, fill: Draw.rgb(0xECECF1))
            }
        }
        ctx.restoreGState()
        return ctx.makeImage()!
    }

    static func scaled(_ image: CGImage, to s: CGSize) -> CGImage {
        let ctx = Draw.context(s)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: s))
        return ctx.makeImage()!
    }

    // MARK: 音を重ねる

    private static func mux(video: URL, sounds: [(URL, Double)], to url: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let videoDuration = try await videoAsset.load(.duration)
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
            let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw YubisashiError("no video track") }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: vTrack, at: .zero)

        for (soundURL, at) in sounds {
            let asset = AVURLAsset(url: soundURL)
            guard let aTrack = try await asset.loadTracks(withMediaType: .audio).first,
                let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let d = try await asset.load(.duration)
            try ca.insertTimeRange(
                CMTimeRange(start: .zero, duration: d), of: aTrack, at: CMTime(seconds: at, preferredTimescale: 600))
        }
        try? FileManager.default.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw YubisashiError("export session failed")
        }
        try await export.export(to: url, as: .mp4)
    }
}

// MARK: - 時間割

struct Timeline {
    var title = 0.0
    var concept = 3.2
    var demo = 7.4
    var recStart = 8.3
    var recDuration = 12.0
    var processing = 1.3
    var doneHold = 1.8
    var outputLength = 8.5
    var agentLength = 9.5
    var endLength = 3.5

    var recStop: Double { recStart + recDuration }
    var output: Double { recStop + processing + doneHold + 0.5 }
    var agent: Double { output + outputLength }
    var end: Double { agent + agentLength }
    var total: Double { end + endLength }
    var cuts: [Double] { [concept, demo, output, agent, end] }
}

// MARK: - 映像

private struct Movie {
    let sc: ConceptVideo.Script
    let tl: Timeline
    let choreo: ConceptVideo.Choreo
    let levels: [Double]
    let chars: [CharStamp]
    let screenList: CGImage
    let screenDetail: CGImage
    let output: ReviewBuilder.Output
    let speechSegments: [Segment]

    func write(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = Int(ConceptVideo.size.width)
        let h = Int(ConceptVideo.size.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000],
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? YubisashiError("writer failed") }
        writer.startSession(atSourceTime: .zero)

        var sim = OverlaySim(samples: choreo.samples)
        let images = loadOutputImages()
        let frames = Int(tl.total * ConceptVideo.fps)
        for i in 0..<frames {
            let t = Double(i) / ConceptVideo.fps
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { throw YubisashiError("no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            Draw.flip(ctx, height: ConceptVideo.size.height)
            drawFrame(ctx, t: t, sim: &sim, images: images)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(ConceptVideo.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? YubisashiError("writer did not complete") }
    }

    private func loadOutputImages() -> [(name: String, image: CGImage)] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: output.framesDir.path)) ?? []
        return files.filter { $0.hasSuffix(".jpg") }.sorted().compactMap { name in
            loadImage(output.framesDir.appendingPathComponent(name)).map { (name, $0) }
        }
    }

    // MARK: 1コマ

    private func drawFrame(_ ctx: CGContext, t: Double, sim: inout OverlaySim, images: [(name: String, image: CGImage)]) {
        let size = ConceptVideo.size
        ctx.setFillColor(Draw.rgb(0x0E0E13))
        ctx.fill(CGRect(origin: .zero, size: size))

        if t < tl.concept {
            drawTitle(ctx, t: t - tl.title)
        } else if t < tl.demo {
            drawConcept(ctx, t: t - tl.concept)
        } else if t < tl.output {
            drawDemo(ctx, t: t, sim: &sim)
        } else if t < tl.agent {
            drawOutput(ctx, t: t - tl.output, images: images)
        } else if t < tl.end {
            drawAgent(ctx, t: t - tl.agent)
        } else {
            drawEnd(ctx, t: t - tl.end)
        }

        // 場面の切り替わりは黒をはさむ
        let fade = tl.cuts.map { max(0, 1 - abs(t - $0) / 0.35) }.max() ?? 0
        let edge = max(0, 1 - t / 0.5, 1 - (tl.total - t) / 0.6)
        let alpha = max(fade, edge)
        if alpha > 0 {
            ctx.setFillColor(Draw.black.copy(alpha: alpha)!)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: タイトル・コンセプト・終わり

    private func drawTitle(_ ctx: CGContext, t: Double) {
        let c = ConceptVideo.size
        let a = ease(t / 0.8)
        ctx.saveGState()
        ctx.setAlpha(a)
        let title = Draw.text(sc.title, 108, .bold, Draw.white)
        Draw.centered(ctx, title, center: CGPoint(x: c.width / 2, y: c.height / 2 - 60 + (1 - a) * 20))
        ctx.setFillColor(Draw.pink)
        let tw = Draw.width(title)
        ctx.fillEllipse(in: CGRect(x: c.width / 2 + tw / 2 + 10, y: c.height / 2 - 50, width: 20, height: 20))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setAlpha(ease((t - 0.6) / 0.8))
        Draw.centered(ctx, Draw.text(sc.tagline, 44, .medium, Draw.rgb(0xD8D8E0)), center: CGPoint(x: c.width / 2, y: c.height / 2 + 70))
        ctx.restoreGState()
    }

    private func drawConcept(_ ctx: CGContext, t: Double) {
        let c = ConceptVideo.size
        ctx.saveGState()
        ctx.setAlpha(ease(t / 0.6))
        Draw.centered(ctx, Draw.text(sc.problem, 40, .medium, Draw.rgb(0xB8B8C4)), center: CGPoint(x: c.width / 2, y: c.height / 2 - 50))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setAlpha(ease((t - 1.4) / 0.6))
        Draw.centered(ctx, Draw.text(sc.solution, 40, .bold, Draw.white), center: CGPoint(x: c.width / 2, y: c.height / 2 + 40))
        ctx.setFillColor(Draw.pink)
        ctx.fill(CGRect(x: c.width / 2 - 60, y: c.height / 2 + 90, width: 120 * ease((t - 1.6) / 0.6), height: 5))
        ctx.restoreGState()
    }

    private func drawEnd(_ ctx: CGContext, t: Double) {
        let c = ConceptVideo.size
        ctx.saveGState()
        ctx.setAlpha(ease(t / 0.6))
        let title = Draw.text(sc.title, 96, .bold, Draw.white)
        Draw.centered(ctx, title, center: CGPoint(x: c.width / 2, y: c.height / 2 - 50))
        ctx.setFillColor(Draw.pink)
        ctx.fillEllipse(in: CGRect(x: c.width / 2 + Draw.width(title) / 2 + 10, y: c.height / 2 - 42, width: 18, height: 18))
        Draw.centered(ctx, Draw.text(sc.endSteps, 38, .medium, Draw.rgb(0xD8D8E0)), center: CGPoint(x: c.width / 2, y: c.height / 2 + 70))
        ctx.restoreGState()
    }

    // MARK: デモ

    private func drawDemo(_ ctx: CGContext, t: Double, sim: inout OverlaySim) {
        let rt = t - tl.recStart  // 記録開始からの時刻
        let detail = rt >= choreo.transition
        ctx.saveGState()
        ctx.setAlpha(ease((t - tl.demo) / 0.4))
        Draw.image(ctx, detail ? screenDetail : screenList, in: CGRect(origin: .zero, size: ConceptVideo.size))
        ctx.restoreGState()

        let recording = rt >= 0 && rt <= tl.recDuration
        drawMenuIcon(ctx, recording: recording, elapsed: rt)

        // 記録中の表示
        if recording {
            let level = rt >= 0 ? levels[min(levels.count - 1, max(0, Int(rt * ConceptVideo.fps)))] : 0
            sim.advance(to: rt)
            drawBorder(ctx, rt: rt)
            sim.draw(ctx, now: rt, level: level, clicks: choreo.click.map { [$0] } ?? [])
        }

        // カーソル（記録前後も表示）
        let cursorT = max(0, min(tl.recDuration, rt))
        drawArrow(ctx, at: OverlaySim.position(choreo.samples, cursorT))

        drawCaption(ctx, rt: rt)
        drawHUD(ctx, t: t, rt: rt)

        // ホットキー
        drawKey(ctx, t: t - (tl.recStart - 0.5), label: sc.keyStart)
        drawKey(ctx, t: t - (tl.recStop - 0.3), label: sc.keyStop)
    }

    private func drawMenuIcon(_ ctx: CGContext, recording: Bool, elapsed: Double) {
        let x = ConceptVideo.size.width - 150
        if recording {
            ctx.setFillColor(Draw.rgb(0xFF3B30))
            ctx.fillEllipse(in: CGRect(x: x - 52, y: 8, width: 14, height: 14))
            Draw.line(ctx, Draw.text(formatTime(elapsed), 14, .medium, Draw.white), x: x - 32, baseline: 20)
        } else {
            Draw.symbol(ctx, "hand.point.up.left", in: CGRect(x: x - 50, y: 5, width: 20, height: 20), color: Draw.white)
        }
    }

    private func drawBorder(_ ctx: CGContext, rt: Double) {
        let intro = ease(rt / 0.4)
        let pulse = 0.72 + 0.28 * cos((rt - 0.4) * .pi / 1.6)
        ctx.saveGState()
        ctx.setAlpha(rt < 0.4 ? intro : pulse)
        ctx.setShadow(offset: .zero, blur: 14, color: Draw.pink)
        ctx.setStrokeColor(Draw.pink)
        ctx.setLineWidth(16 - 13 * intro)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: ConceptVideo.size).insetBy(dx: 2, dy: 2), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawArrow(_ ctx: CGContext, at p: CGPoint) {
        let s = 1.45
        let pts: [(Double, Double)] = [(0, 0), (0, 21), (5, 16.2), (8.6, 23.6), (11.6, 22.3), (8.1, 15.1), (15, 15.1)]
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: Draw.black.copy(alpha: 0.35))
        ctx.move(to: CGPoint(x: p.x, y: p.y))
        for q in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x + q.0 * s, y: p.y + q.1 * s)) }
        ctx.closePath()
        ctx.setFillColor(Draw.black)
        ctx.setStrokeColor(Draw.white)
        ctx.setLineWidth(2)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    /// 字幕: 話した所まで出し、指示語はピンク、その後に番号を付ける
    private func drawCaption(_ ctx: CGContext, rt: Double) {
        guard rt >= 0, rt <= tl.recDuration + 0.6 else { return }
        // どちらの文か
        let spoken = chars.filter { $0.start <= rt }
        guard let last = spoken.last else { return }
        let gapIndex = chars.indices.dropFirst().first { chars[$0].start - chars[$0 - 1].end > 0.6 } ?? chars.count
        let inSecond = chars.firstIndex { $0.start == last.start && $0.ch == last.ch }.map { $0 >= gapIndex } ?? false
        let seg = speechSegments.count >= 2 ? speechSegments[inSecond ? 1 : 0] : speechSegments.first
        let pool = inSecond ? Array(chars[gapIndex...]) : Array(chars[..<gapIndex])
        let revealed = pool.filter { $0.start <= rt }.map(\.ch).joined().count
        guard revealed > 0 else { return }

        let marked = seg?.markedText ?? pool.map(\.ch).joined()
        let font = 34.0
        let out = NSMutableAttributedString()
        var plainCount = 0
        var pending = ""
        for ch in marked {
            if isCircled(ch) {
                guard plainCount <= revealed else { break }
                // 番号の直前の指示語をピンクにする
                let text = Draw.text(pending, font, .medium, Draw.white)
                if let n = Int(exactly: circledNumber(ch)), let a = seg?.anchors.first(where: { $0.number == n }),
                    let word = a.words.sorted(by: { $0.count > $1.count }).first(where: { pending.lowercased().hasSuffix($0.lowercased()) })
                {
                    let head = String(pending.dropLast(word.count))
                    out.append(Draw.text(head, font, .medium, Draw.white))
                    out.append(Draw.text(String(pending.suffix(word.count)), font, .bold, Draw.pink))
                } else {
                    out.append(text)
                }
                out.append(Draw.text(String(ch), font, .bold, Draw.pink))
                pending = ""
                continue
            }
            guard plainCount < revealed else { break }
            pending.append(ch)
            plainCount += 1
        }
        out.append(Draw.text(pending, font, .medium, Draw.white))

        let maxWidth = 1500.0
        let lines = Draw.wrap(out, width: maxWidth)
        let lineH = font * 1.45
        let boxH = Double(lines.count) * lineH + 30
        let widest = lines.map { Draw.width($0) }.max() ?? 0
        let box = CGRect(x: 960 - (widest + 120) / 2, y: 1000 - boxH - 12, width: widest + 120, height: boxH)
        Draw.rrect(ctx, box, 18, fill: Draw.black.copy(alpha: 0.72))
        Draw.symbol(ctx, "mic.fill", in: CGRect(x: box.minX + 24, y: box.minY + 15 + (lineH - 30) / 2, width: 26, height: 30), color: Draw.pink)
        for (i, line) in lines.enumerated() {
            Draw.line(ctx, line, x: box.minX + 74, baseline: box.minY + 15 + Double(i) * lineH + font * 1.05)
        }
    }

    private func isCircled(_ c: Character) -> Bool { circledNumber(c) > 0 }

    private func circledNumber(_ c: Character) -> Int {
        guard let v = c.unicodeScalars.first?.value else { return 0 }
        switch v {
        case 0x2460...0x2473: return Int(v - 0x2460 + 1)
        case 0x3251...0x325F: return Int(v - 0x3251 + 21)
        case 0x32B1...0x32BF: return Int(v - 0x32B1 + 36)
        default: return 0
        }
    }

    /// 画面下の帯（アプリの HUD と同じ見た目）
    private func drawHUD(_ ctx: CGContext, t: Double, rt: Double) {
        let startShow = tl.recStart - 0.35
        let endShow = tl.recStop + tl.processing + tl.doneHold
        guard t >= startShow, t <= endShow + 0.3 else { return }
        let alpha = t > endShow ? 1 - (t - endShow) / 0.3 : 1
        let fs = 17.0
        var items: [(NSAttributedString?, String?)] = []  // テキストか、特別な部品
        let white = Draw.white
        let dim = Draw.white.copy(alpha: 0.6)!
        if t < tl.recStart {
            items = [(nil, "spinner"), (Draw.text(L.s("開始しています…", "Starting…"), fs, .medium, white), nil)]
        } else if rt <= tl.recDuration {
            items = [
                (nil, "dot"), (Draw.text(L.s("記録中", "Recording"), fs, .medium, white), nil),
                (Draw.text(formatTime(rt), fs, .medium, dim), nil), (nil, "bars"), (nil, "divider"),
                (Draw.text(L.s("⌃⌥R で終了", "⌃⌥R to stop"), fs, .medium, dim), nil),
            ]
        } else if t < tl.recStop + tl.processing {
            items = [(nil, "spinner"), (Draw.text(L.s("書き出しています…", "Exporting…"), fs, .medium, white), nil)]
        } else {
            items = [
                (nil, "check"), (Draw.text(L.s("コピーしました", "Copied"), fs, .medium, white), nil),
                (Draw.text(L.s("エージェントに貼り付けてください", "Paste it into your agent"), fs, .medium, dim), nil),
            ]
        }
        let widths = items.map { item -> Double in
            if let text = item.0 { return Draw.width(text) }
            switch item.1 {
            case "bars": return 26
            case "divider": return 1
            default: return 14
            }
        }
        let spacing = 12.0
        let total = widths.reduce(0, +) + spacing * Double(items.count - 1) + 40
        let h = 44.0
        let rect = CGRect(x: 960 - total / 2, y: 1080 - 30 - h, width: total, height: h)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: Draw.black.copy(alpha: 0.3))
        Draw.rrect(ctx, rect, h / 2, fill: Draw.rgb(0x111114).copy(alpha: 0.92)!, stroke: Draw.white.copy(alpha: 0.14), lw: 1)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        var x = rect.minX + 20
        let cy = rect.midY
        for (k, item) in items.enumerated() {
            if let text = item.0 {
                Draw.line(ctx, text, x: x, baseline: cy + fs * 0.36)
            } else {
                switch item.1 {
                case "dot":
                    let a = 0.65 + 0.35 * cos(t * .pi / 0.8)
                    ctx.setFillColor(Draw.rgb(0xFF3B30).copy(alpha: a)!)
                    ctx.fillEllipse(in: CGRect(x: x + 2, y: cy - 5, width: 10, height: 10))
                case "spinner":
                    ctx.setStrokeColor(Draw.pink)
                    ctx.setLineWidth(2.2)
                    ctx.setLineCap(.round)
                    let a0 = t * 2 * .pi / 0.8
                    ctx.addArc(center: CGPoint(x: x + 7, y: cy), radius: 7, startAngle: a0, endAngle: a0 + 1.4 * .pi, clockwise: false)
                    ctx.strokePath()
                case "check":
                    Draw.symbol(ctx, "checkmark.circle.fill", in: CGRect(x: x - 2, y: cy - 9, width: 18, height: 18), color: Draw.rgb(0x30D158))
                case "bars":
                    let level = levels[min(levels.count - 1, max(0, Int(rt * ConceptVideo.fps)))]
                    for (i, wgt) in [0.45, 0.8, 1.0, 0.7, 0.5].enumerated() {
                        let bh = 4 + 16 * level * wgt
                        Draw.rrect(ctx, CGRect(x: x + Double(i) * 5.5, y: cy - bh / 2, width: 3, height: bh), 1.5, fill: Draw.pink.copy(alpha: level > 0.02 ? 1 : 0.45)!)
                    }
                case "divider":
                    ctx.setFillColor(Draw.white.copy(alpha: 0.22)!)
                    ctx.fill(CGRect(x: x, y: cy - 8, width: 1, height: 16))
                default:
                    break
                }
            }
            x += widths[k] + spacing
        }
        ctx.restoreGState()
    }

    /// 押したホットキーを見せる
    private func drawKey(_ ctx: CGContext, t: Double, label: String) {
        guard t >= 0, t <= 1.3 else { return }
        let appear = ease(t / 0.18)
        let alpha = t > 1.0 ? 1 - (t - 1.0) / 0.3 : appear
        let press = t > 0.25 && t < 0.45 ? 0.94 : 1.0
        let keys = ["⌃", "⌥", "R"]
        let k = 64.0 * press
        let gap = 12.0
        let labelText = Draw.text(label, 26, .semibold, Draw.white)
        let totalW = Double(keys.count) * k + Double(keys.count - 1) * gap + 24 + Draw.width(labelText)
        var x = 960 - totalW / 2
        let y = 780.0 + (1 - appear) * 12
        ctx.saveGState()
        ctx.setAlpha(alpha)
        Draw.rrect(ctx, CGRect(x: x - 22, y: y - 18, width: totalW + 44, height: k + 36), 22, fill: Draw.black.copy(alpha: 0.55))
        for key in keys {
            let r = CGRect(x: x, y: y + (64 - k) / 2, width: k, height: k)
            Draw.rrect(ctx, r.offsetBy(dx: 0, dy: 3), 12, fill: Draw.rgb(0x8A8A96))
            Draw.rrect(ctx, r, 12, fill: Draw.rgb(0xF4F4F7))
            Draw.centered(ctx, Draw.text(key, 30, .semibold, Draw.rgb(0x22222A)), center: CGPoint(x: r.midX, y: r.midY))
            x += k + gap
        }
        Draw.line(ctx, labelText, x: x + 12, baseline: y + 41)
        ctx.restoreGState()
    }

    // MARK: 書き出される記録

    private func drawOutput(_ ctx: CGContext, t: Double, images: [(name: String, image: CGImage)]) {
        Draw.line(ctx, Draw.text(sc.outputTitle, 44, .bold, Draw.white), x: 80, baseline: 110)
        Draw.line(ctx, Draw.text("review.md  +  frames/*.jpg", 22, .regular, Draw.rgb(0x9A9AA8)), x: 82, baseline: 148)

        // 左: 軌跡を描き込んだ画像を順に見せる
        guard !images.isEmpty else { return }
        let per = (tl.outputLength - 0.6) / Double(images.count)
        let idx = min(images.count - 1, Int(max(0, t - 0.3) / per))
        let local = max(0, t - 0.3) - Double(idx) * per
        let frame = CGRect(x: 80, y: 190, width: 1060, height: 1060 * Double(images[idx].image.height) / Double(images[idx].image.width))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: Draw.black.copy(alpha: 0.5))
        ctx.setFillColor(Draw.black)
        ctx.fill(frame)
        ctx.restoreGState()
        if idx > 0, local < 0.3 {
            Draw.image(ctx, images[idx - 1].image, in: frame)
        }
        ctx.saveGState()
        ctx.setAlpha(idx > 0 ? ease(local / 0.3) : ease(t / 0.4))
        Draw.image(ctx, images[idx].image, in: frame)
        ctx.restoreGState()

        // 右: review.md の中身（要点）
        let panel = CGRect(x: 1180, y: 190, width: 660, height: 720)
        Draw.rrect(ctx, panel, 16, fill: Draw.rgb(0x1A1A21), stroke: Draw.white.copy(alpha: 0.08), lw: 1)
        Draw.line(ctx, Draw.text("review.md", 18, .semibold, Draw.rgb(0x9A9AA8), mono: true), x: panel.minX + 28, baseline: panel.minY + 40)
        var y = panel.minY + 80
        let currentSegment = Int(images[idx].name.prefix(2)) ?? 1
        for seg in speechSegments {
            let active = seg.index == currentSegment
            if active {
                ctx.setFillColor(Draw.pink)
                ctx.fill(CGRect(x: panel.minX + 14, y: y - 26, width: 4, height: 34 + 52 + Double(seg.anchors.count) * 38))
            }
            Draw.line(ctx, Draw.text("## \(seg.index). \(formatTime(seg.start))–\(formatTime(seg.end))", 20, .bold, active ? Draw.white : Draw.rgb(0x8A8A96), mono: true), x: panel.minX + 32, baseline: y)
            y += 12
            let quote = NSMutableAttributedString()
            for ch in seg.markedText {
                quote.append(Draw.text(String(ch), 19, isCircled(ch) ? .bold : .regular, isCircled(ch) ? Draw.pink : (active ? Draw.rgb(0xE8E8EE) : Draw.rgb(0x8A8A96))))
            }
            for line in Draw.wrap(quote, width: panel.width - 80) {
                y += 30
                Draw.line(ctx, line, x: panel.minX + 32, baseline: y)
            }
            y += 14
            for a in seg.anchors {
                y += 38
                let row = Draw.text(circled(a.number), 21, .bold, Draw.pink)
                row.append(Draw.text("  \(formatTime(a.t))  \(ReviewBuilder.motionLabel(a, scale: 1600.0 / 1920.0))", 17, .regular, active ? Draw.rgb(0xD0D0D8) : Draw.rgb(0x7A7A86)))
                Draw.line(ctx, row, x: panel.minX + 32, baseline: y)
                if let hex = lastHex(a.color) {
                    let rx = panel.maxX - 150
                    Draw.rrect(ctx, CGRect(x: rx, y: y - 16, width: 18, height: 18), 4, fill: Draw.hex(hex), stroke: Draw.white.copy(alpha: 0.3), lw: 1)
                    Draw.line(ctx, Draw.text(hex, 16, .regular, Draw.rgb(0x9A9AA8), mono: true), x: rx + 26, baseline: y)
                }
            }
            y += 54
        }

        ctx.saveGState()
        ctx.setAlpha(ease((t - 1.0) / 0.5))
        let note = Draw.text(sc.outputNote, 24, .medium, Draw.white)
        Draw.symbol(ctx, "doc.on.clipboard", in: CGRect(x: 80, y: 960, width: 26, height: 30), color: Draw.pink)
        Draw.line(ctx, note, x: 120, baseline: 985)
        ctx.restoreGState()
    }

    private func lastHex(_ s: String?) -> String? {
        guard let s else { return nil }
        guard let re = try? NSRegularExpression(pattern: "#[0-9A-F]{6}") else { return nil }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last.map { ns.substring(with: $0.range) }
    }

    // MARK: エージェント

    private func drawAgent(_ ctx: CGContext, t: Double) {
        Draw.line(ctx, Draw.text(sc.agentTitle, 44, .bold, Draw.white), x: 260, baseline: 110)
        let panel = CGRect(x: 260, y: 160, width: 1400, height: 800)
        Draw.rrect(ctx, panel, 16, fill: Draw.rgb(0x111318), stroke: Draw.white.copy(alpha: 0.1), lw: 1)
        ctx.setFillColor(Draw.rgb(0x1B1E25))
        ctx.fill(CGRect(x: panel.minX + 1, y: panel.minY + 1, width: panel.width - 2, height: 46))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Draw.rgb(c))
            ctx.fillEllipse(in: CGRect(x: panel.minX + 20 + Double(i) * 22, y: panel.minY + 16, width: 14, height: 14))
        }
        let label = Draw.text(sc.agentLabel, 16, .medium, Draw.rgb(0x8A8A96))
        Draw.line(ctx, label, x: panel.maxX - 24 - Draw.width(label), baseline: panel.minY + 30)

        let mono = 23.0
        var y = panel.minY + 100
        ctx.saveGState()
        ctx.setAlpha(ease((t - 0.3) / 0.3))
        let images = output.segments.reduce(0) { $0 + $1.parts.filter { $0.frameFile != nil }.count }
        let pasted = NSMutableAttributedString(attributedString: Draw.text("› ", mono, .bold, Draw.pink, mono: true))
        pasted.append(Draw.text(sc.agentPasted(output.segments.count, images), mono, .regular, Draw.rgb(0xC8C8D2), mono: true))
        Draw.line(ctx, pasted, x: panel.minX + 40, baseline: y)
        ctx.restoreGState()

        // 返答を1文字ずつ出す
        let color = speechSegments.first?.anchors.dropFirst().first.flatMap { lastHex($0.color) } ?? "#2D6AE9"
        let reply = sc.agentReply(color)
        let perSecond = L.lang == .ja ? 34.0 : 70.0
        let shown = Int(max(0, t - 1.3) * perSecond)
        y += 64
        var count = 0
        for line in reply.components(separatedBy: "\n") {
            guard count < shown else { break }
            let visible = String(line.prefix(max(0, shown - count)))
            count += line.count + 1
            let isHeading = line.hasPrefix("改善項目") || line.hasPrefix("Improvements")
            let isNumbered = line.first?.isNumber == true
            let isQuestion = line.hasPrefix("確認") || line.hasPrefix("Question")
            let color = isQuestion ? Draw.pink : (isHeading || isNumbered ? Draw.white : Draw.rgb(0xAEB0BC))
            // 番号（①②）は等幅フォントだと潰れるので、ピンクの通常フォントで大きめに出す
            let styled = NSMutableAttributedString()
            for ch in visible {
                styled.append(
                    isCircled(ch)
                        ? Draw.text(String(ch), mono + 3, .bold, Draw.pink)
                        : Draw.text(String(ch), mono, isHeading || isNumbered ? .bold : .regular, color, mono: true))
            }
            Draw.line(ctx, styled, x: panel.minX + 40, baseline: y)
            y += line.isEmpty ? 22 : 40
        }
    }

    private func ease(_ x: Double) -> Double {
        let u = max(0, min(1, x))
        return u * u * (3 - 2 * u)
    }
}

// MARK: - 記録中の表示（CursorOverlayView と同じ見た目を CGContext に描く）

private struct OverlaySim {
    let samples: [CursorSample]
    private var index = 0
    private var dwellAnchor: (p: CGPoint, t: Double)?
    private var registered = false
    private var pins: [(p: CGPoint, t: Double)] = []

    init(samples: [CursorSample]) { self.samples = samples }

    static func position(_ s: [CursorSample], _ t: Double) -> CGPoint {
        let i = min(s.count - 1, max(0, Int(t * 60)))
        return CGPoint(x: s[i].x, y: s[i].y)
    }

    /// t までのカーソル位置を順に読み、止まる判定を進める
    mutating func advance(to t: Double) {
        while index < samples.count, samples[index].t <= t {
            let s = samples[index]
            let p = CGPoint(x: s.x, y: s.y)
            if let a = dwellAnchor, hypot(a.p.x - p.x, a.p.y - p.y) <= Analyzer.dwellRadius {
                if !registered, s.t - a.t >= Analyzer.dwellMinDuration {
                    registered = true
                    pins.append((a.p, s.t))
                }
            } else {
                dwellAnchor = (p, s.t)
                registered = false
            }
            index += 1
        }
    }

    func draw(_ ctx: CGContext, now: Double, level: Double, clicks: [Double]) {
        let pink = Draw.pink
        // 軌跡の残像
        let recent = samples.filter { $0.t <= now && now - $0.t <= 0.9 }
        ctx.setLineWidth(4)
        ctx.setLineCap(.butt)
        for (a, b) in zip(recent, recent.dropFirst()) {
            let age = now - b.t
            ctx.setStrokeColor(pink.copy(alpha: 0.1 + 0.65 * (1 - age / 0.9))!)
            ctx.move(to: CGPoint(x: a.x, y: a.y))
            ctx.addLine(to: CGPoint(x: b.x, y: b.y))
            ctx.strokePath()
        }

        // 止まったときのリング
        if let a = dwellAnchor, !registered {
            let progress = max(0, min(1, (now - a.t - 0.08) / (Analyzer.dwellMinDuration - 0.08)))
            if progress > 0 {
                ctx.setStrokeColor(pink)
                ctx.setLineWidth(3)
                ctx.setLineCap(.round)
                ctx.addArc(center: a.p, radius: 27, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * progress, clockwise: false)
                ctx.strokePath()
            }
        }
        // 判定された位置の点と広がる輪
        for pin in pins where now - pin.t < 1.4 {
            let age = now - pin.t
            let a = age < 0.9 ? 1 : 1 - (age - 0.9) / 0.5
            ctx.setFillColor(pink.copy(alpha: a)!)
            ctx.setStrokeColor(Draw.white.copy(alpha: a)!)
            ctx.setLineWidth(2)
            ctx.addEllipse(in: CGRect(x: pin.p.x - 6, y: pin.p.y - 6, width: 12, height: 12))
            ctx.drawPath(using: .fillStroke)
            if age < 0.35 {
                ctx.setStrokeColor(pink.copy(alpha: 0.9 * (1 - age / 0.35))!)
                ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: pin.p.x - 27, y: pin.p.y - 27, width: 54, height: 54))
            }
        }
        // クリックの波紋
        for c in clicks where now >= c && now - c < 0.45 {
            let u = (now - c) / 0.45
            let e = 1 - (1 - u) * (1 - u)
            let r = 34 * (0.2 + 0.8 * e)
            let p = Self.position(samples, c)
            ctx.setFillColor(pink.copy(alpha: 0.15 * (1 - u))!)
            ctx.setStrokeColor(pink.copy(alpha: 1 - u)!)
            ctx.setLineWidth(3)
            ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.drawPath(using: .fillStroke)
        }
        // カーソルの輪
        let p = Self.position(samples, now)
        let r = 15 + 9 * level
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6 * level, color: pink)
        ctx.setFillColor(pink.copy(alpha: 0.08 + 0.17 * level)!)
        ctx.setStrokeColor(pink)
        ctx.setLineWidth(2 + 2 * level)
        ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }
}

// MARK: - 描画の小道具（左上原点に反転した CGContext 用）

enum Draw {
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let pink = CGColor(srgbRed: 1.0, green: 0.12, blue: 0.56, alpha: 1)

    static func rgb(_ v: Int) -> CGColor {
        CGColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ s: String) -> CGColor { rgb(Int(s.dropFirst(), radix: 16) ?? 0) }

    static func context(_ size: CGSize) -> CGContext {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func flip(_ ctx: CGContext, height: CGFloat) {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }

    static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: CGColor, mono: Bool = false)
        -> NSMutableAttributedString
    {
        let font =
            (mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight))
            as CTFont
        return NSMutableAttributedString(
            string: s,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
    }

    static func width(_ a: NSAttributedString) -> Double {
        Double(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil))
    }

    static func line(_ ctx: CGContext, _ a: NSAttributedString, x: Double, baseline: Double) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
        ctx.restoreGState()
    }

    static func centered(_ ctx: CGContext, _ a: NSAttributedString, center: CGPoint) {
        let l = CTLineCreateWithAttributedString(a)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(l, &ascent, &descent, nil)
        line(ctx, a, x: center.x - w / 2, baseline: center.y + (ascent - descent) / 2)
    }

    /// 幅に収まるように行を分ける
    static func wrap(_ a: NSAttributedString, width: Double) -> [NSAttributedString] {
        let typesetter = CTTypesetterCreateWithAttributedString(a)
        var lines: [NSAttributedString] = []
        var start = 0
        while start < a.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, width)
            guard count > 0 else { break }
            lines.append(a.attributedSubstring(from: NSRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    static func rrect(_ ctx: CGContext, _ r: CGRect, _ radius: Double, fill: CGColor?, stroke: CGColor? = nil, lw: Double = 1) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let fill {
            ctx.setFillColor(fill)
            ctx.addPath(path)
            ctx.fillPath()
        }
        if let stroke {
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(lw)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// 反転した座標系で、画像を正しい向きに描く
    static func image(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    static func symbol(_ ctx: CGContext, _ name: String, in r: CGRect, color: CGColor) {
        guard
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: r.height, weight: .regular).applying(.init(paletteColors: [NSColor(cgColor: color) ?? .white])))
        else { return }
        var rect = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let aspect = Double(cg.width) / Double(cg.height)
        let w = min(r.width, r.height * aspect)
        let h = w / aspect
        image(ctx, cg, in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }
}
