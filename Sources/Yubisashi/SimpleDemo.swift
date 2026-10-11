import AVFoundation
import AppKit
import CoreText

/// 開発用: 明るい背景の、シンプルな英語のデモ動画を作る。
///
/// 1. `Yubisashi --simple-demo-prepare <dir>` で記録を作る（<dir>/review/review.md）
/// 2. その review.md を実際にエージェントへ渡し、返答を <dir>/agent-output.md に保存する
/// 3. `Yubisashi --simple-demo <dir>` で動画を作る（<dir>/yubisashi-demo.mp4）
///
/// 画面は作り物のアプリで、声は合成音声。記録中の表示・書き出される記録は Yubisashi の処理そのもの。
/// エージェントの返答は実際の出力を抜粋して使い、作り話は入れない。
enum SimpleDemo {
    static func prepare(dir: URL) async throws -> ConceptVideo.Recorded {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try await ConceptVideo.record(
            work: dir.appendingPathComponent("work"), lang: .en, reviewDir: dir.appendingPathComponent("review"),
            wallpaper: .sky)
    }

    static func run(dir: URL) async throws -> URL {
        let agentURL = dir.appendingPathComponent("agent-output.md")
        guard let agent = try? String(contentsOf: agentURL, encoding: .utf8) else {
            throw YubisashiError("agent-output.md がありません。先に --simple-demo-prepare を実行し、エージェントの返答を保存してください。")
        }
        let rec = try await prepare(dir: dir)

        var tl = Timeline()
        tl.demo = 3.4
        tl.recStart = 4.6
        tl.recDuration = rec.duration
        let film = Film(rec: rec, tl: tl, agent: agent)
        let silent = dir.appendingPathComponent("work/video.mp4")
        try await film.write(to: silent)

        let out = dir.appendingPathComponent("yubisashi-demo.mp4")
        let sys = URL(fileURLWithPath: "/System/Library/Sounds")
        try await ConceptVideo.muxPublic(
            video: silent,
            sounds: [
                (rec.voiceURL, tl.recStart), (sys.appendingPathComponent("Tink.aiff"), tl.recStart),
                (sys.appendingPathComponent("Pop.aiff"), tl.recStop),
                (sys.appendingPathComponent("Glass.aiff"), tl.recStop + tl.processing),
            ], to: out)
        return out
    }
}

private struct Film {
    let rec: ConceptVideo.Recorded
    let tl: Timeline
    let agent: String

    // 場面の切り替わり
    var outputStart: Double { tl.recStop + tl.processing + tl.doneHold + 0.6 }
    var agentStart: Double { outputStart + 7.5 }
    var benchStart: Double { agentStart + 9.0 }
    var endStart: Double { benchStart + 6.0 }
    var total: Double { endStart + 4.5 }

    let bg = Draw.rgb(0xF5F5F7)
    let ink = Draw.rgb(0x1D1D1F)
    let gray = Draw.rgb(0x6E6E73)
    /// アプリの画面を置く枠（1920×1080 の画面を 2/3 に縮める）
    let frame = CGRect(x: 320, y: 196, width: 1280, height: 720)

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

        let movie = Movie(
            sc: ConceptVideo.script(.en), tl: tl, choreo: rec.choreo, levels: rec.levels, chars: rec.chars,
            screenList: rec.screenList, screenDetail: rec.screenDetail, output: rec.output,
            speechSegments: rec.output.segments.filter(\.speech))
        var sim = OverlaySim(samples: rec.choreo.samples)
        let images = ["01.jpg", "02b.jpg"].compactMap { loadImage(rec.output.framesDir.appendingPathComponent($0)) }

        for i in 0..<Int(total * ConceptVideo.fps) {
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
            draw(ctx, t: t, movie: movie, sim: &sim, images: images)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(ConceptVideo.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? YubisashiError("writer did not complete") }
    }

    // MARK: 1コマ

    private func draw(_ ctx: CGContext, t: Double, movie: Movie, sim: inout OverlaySim, images: [CGImage]) {
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: ConceptVideo.size))

        if t < tl.demo {
            headline(ctx, "Point at it. Say it.", sub: "Your coding agent knows which “this” you mean.", t: t, y: 470, size: 84)
        } else if t < outputStart {
            demo(ctx, t: t, movie: movie, sim: &sim)
        } else if t < agentStart {
            output(ctx, t: t - outputStart, images: images)
        } else if t < benchStart {
            agentScene(ctx, t: t - agentStart)
        } else if t < endStart {
            bench(ctx, t: t - benchStart)
        } else {
            end(ctx, t: t - endStart)
        }

        // 場面の切り替わりは、背景色で一瞬消す
        let cuts = [tl.demo, outputStart, agentStart, benchStart, endStart]
        let fade = cuts.map { max(0, 1 - abs(t - $0) / 0.3) }.max() ?? 0
        let edge = max(0, 1 - t / 0.4, 1 - (total - t) / 0.5)
        let a = max(fade, edge)
        if a > 0 {
            ctx.setFillColor(bg.copy(alpha: a)!)
            ctx.fill(CGRect(origin: .zero, size: ConceptVideo.size))
        }
    }

    // MARK: 場面

    private func demo(_ ctx: CGContext, t: Double, movie: Movie, sim: inout OverlaySim) {
        let stopped = t >= tl.recStop
        headline(
            ctx, stopped ? "Stop. It’s on your clipboard." : "Press ⌃⌥R. Point and talk.", sub: nil,
            t: stopped ? t - tl.recStop : t - tl.demo, y: 120, size: 52)

        // アプリの画面（枠の中に 2/3 で描く）
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 50, color: Draw.black.copy(alpha: 0.18))
        Draw.rrect(ctx, frame, 22, fill: Draw.white)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 22, cornerHeight: 22, transform: nil))
        ctx.clip()
        ctx.translateBy(x: frame.minX, y: frame.minY)
        ctx.scaleBy(x: frame.width / ConceptVideo.size.width, y: frame.height / ConceptVideo.size.height)
        movie.drawScreen(ctx, t: t, sim: &sim, hud: true)
        ctx.restoreGState()

        subtitle(ctx, t: t)
        hotkey(ctx, t: t - (tl.recStart - 0.4))
        hotkey(ctx, t: t - (tl.recStop - 0.3))

        // 作り物であることを明記する
        let note = Draw.text(
            "Mock app and synthetic voice. The overlays and the exported review are produced by Yubisashi.", 17, .regular,
            gray)
        Draw.line(ctx, note, x: frame.minX, baseline: frame.maxY + 108)
    }

    /// 話している文を、その場の字幕として出す（this / that / here はピンク）
    private func subtitle(_ ctx: CGContext, t: Double) {
        let rt = t - tl.recStart
        guard rt >= 0, rt <= tl.recDuration + 0.4 else { return }
        let spoken = rec.chars.filter { $0.start <= rt }
        guard !spoken.isEmpty else { return }
        // 間が空いたところで文を区切り、今の文だけを出す
        var sentences: [[CharStamp]] = [[]]
        for (i, c) in rec.chars.enumerated() {
            if i > 0, c.start - rec.chars[i - 1].end > 0.6, !sentences[sentences.count - 1].isEmpty { sentences.append([]) }
            sentences[sentences.count - 1].append(c)
        }
        guard let current = sentences.last(where: { ($0.first?.start ?? .infinity) <= rt }) else { return }
        let shown = current.filter { $0.start <= rt }.map(\.ch).joined().trimmingCharacters(in: .whitespaces)
        guard !shown.isEmpty else { return }
        // 話し終わって少したったら消す
        if let last = current.last, rt > last.end + 1.2 { return }

        let size = 30.0
        let text = NSMutableAttributedString(attributedString: Draw.text("“", size, .medium, Draw.white.copy(alpha: 0.6)!))
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let pointing = ["this", "that", "here", "these", "those", "there"].contains(bare)
            text.append(Draw.text(word, size, pointing ? .bold : .medium, pointing ? Draw.pink : Draw.white))
            word = ""
        }
        for ch in shown {
            if ch == " " {
                flush()
                text.append(Draw.text(" ", size, .medium, Draw.white))
            } else {
                word.append(ch)
            }
        }
        flush()
        text.append(Draw.text("”", size, .medium, Draw.white.copy(alpha: 0.6)!))

        let lines = Draw.wrap(text, width: 1300)
        let lineH = size * 1.4
        let widest = lines.map { Draw.width($0) }.max() ?? 0
        let boxH = Double(lines.count) * lineH + 26
        let box = CGRect(x: 960 - (widest + 64) / 2, y: frame.maxY + 26, width: widest + 64, height: boxH)
        Draw.rrect(ctx, box, min(boxH / 2, 30), fill: ink.copy(alpha: 0.92)!)
        for (i, line) in lines.enumerated() {
            Draw.line(ctx, line, x: box.minX + 32, baseline: box.minY + 13 + Double(i) * lineH + size * 1.02)
        }
    }

    private func hotkey(_ ctx: CGContext, t: Double) {
        guard t >= 0, t <= 1.1 else { return }
        let alpha = t < 0.15 ? t / 0.15 : (t > 0.85 ? (1.1 - t) / 0.25 : 1)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        var x = 960 - (3 * 64 + 2 * 12) / 2.0
        let y = frame.maxY + 30
        for key in ["⌃", "⌥", "R"] {
            let r = CGRect(x: x, y: y, width: 64, height: 64)
            Draw.rrect(ctx, r.offsetBy(dx: 0, dy: 3), 12, fill: Draw.rgb(0xC7C7CC))
            Draw.rrect(ctx, r, 12, fill: Draw.white, stroke: Draw.rgb(0xD1D1D6), lw: 1)
            Draw.centered(ctx, Draw.text(key, 30, .semibold, ink), center: CGPoint(x: r.midX, y: r.midY))
            x += 76
        }
        ctx.restoreGState()
    }

    private func output(_ ctx: CGContext, t: Double, images: [CGImage]) {
        headline(ctx, "Every “this” is linked to a spot.", sub: "review.md and annotated screenshots, ready to paste.", t: t, y: 120, size: 52)
        guard !images.isEmpty else { return }
        // 左: 書き出された画像（2枚を順に）
        let idx = t < 3.6 || images.count < 2 ? 0 : 1
        let img = images[idx]
        let card = CGRect(x: 110, y: 250, width: 1000, height: 1000 * Double(img.height) / Double(img.width))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: Draw.black.copy(alpha: 0.16))
        Draw.rrect(ctx, card, 16, fill: Draw.white)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.clip()
        ctx.setAlpha(min(1, (idx == 0 ? t : t - 3.6) / 0.3))
        Draw.image(ctx, img, in: card)
        ctx.restoreGState()

        // 右: review.md の該当部分（書き出された文をそのまま）
        let panel = CGRect(x: 1160, y: 250, width: 650, height: card.height)
        Draw.rrect(ctx, panel, 16, fill: Draw.white, stroke: Draw.rgb(0xE5E5EA), lw: 1)
        Draw.line(ctx, Draw.text("review.md", 18, .semibold, gray, mono: true), x: panel.minX + 28, baseline: panel.minY + 42)
        var y = panel.minY + 92
        for seg in rec.output.segments where seg.speech {
            let active = (seg.index == 1) == (idx == 0)
            Draw.line(ctx, Draw.text("## \(seg.index)", 20, .bold, active ? ink : gray, mono: true), x: panel.minX + 28, baseline: y)
            let quote = NSMutableAttributedString()
            for ch in seg.markedText {
                let isNumber = (0x2460...0x2473).contains(ch.unicodeScalars.first!.value)
                quote.append(Draw.text(String(ch), 21, isNumber ? .bold : .regular, isNumber ? Draw.pink : (active ? ink : gray)))
            }
            for line in Draw.wrap(quote, width: panel.width - 56) {
                y += 34
                Draw.line(ctx, line, x: panel.minX + 28, baseline: y)
            }
            for a in seg.anchors {
                y += 32
                let row = NSMutableAttributedString(attributedString: Draw.text(circled(a.number) + "  ", 19, .bold, Draw.pink))
                row.append(Draw.text(ReviewBuilder.motionLabel(a, scale: 1600.0 / 1920.0), 18, .regular, active ? gray : Draw.rgb(0xAEAEB2)))
                Draw.line(ctx, row, x: panel.minX + 28, baseline: y)
            }
            y += 50
        }
    }

    /// 実際のエージェントの返答を、文言を変えずに抜粋して出す
    private func agentScene(_ ctx: CGContext, t: Double) {
        headline(ctx, "Paste it into Claude Code.", sub: "Actual response, unedited excerpt.", t: t, y: 120, size: 52)
        let panel = CGRect(x: 260, y: 230, width: 1400, height: 760)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: Draw.black.copy(alpha: 0.14))
        Draw.rrect(ctx, panel, 18, fill: Draw.white)
        ctx.restoreGState()
        var y = panel.minY + 58
        let prompt = NSMutableAttributedString(attributedString: Draw.text("› ", 22, .bold, Draw.pink, mono: true))
        prompt.append(Draw.text("[pasted review.md]  ", 22, .regular, gray, mono: true))
        prompt.append(Draw.text("List the changes you’d make.", 22, .regular, ink, mono: true))
        Draw.line(ctx, prompt, x: panel.minX + 44, baseline: y)
        y += 56

        // 見出しや太字の印（# や **）は見た目に置き換え、文言はそのまま
        let lines = agent.components(separatedBy: "\n")
        let budget = Int(max(0, t - 0.6) * 300)
        var used = 0
        for raw in lines {
            guard y < panel.maxY - 30, used < budget else { break }
            // コードの印（`）は書式なので外す。文言は変えない
            var line = raw.replacingOccurrences(of: "`", with: "")
            var size = 22.0
            var weight: NSFont.Weight = .regular
            if line.hasPrefix("#") {
                line = line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                size = 24
                weight = .bold
            }
            let visible = String(line.prefix(max(0, budget - used)))
            used += line.count + 1
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                y += 14
                continue
            }
            let styled = NSMutableAttributedString()
            for (k, part) in visible.components(separatedBy: "**").enumerated() {
                styled.append(Draw.text(part, size, k % 2 == 1 ? .bold : weight, ink))
            }
            for wrapped in Draw.wrap(styled, width: panel.width - 88) {
                guard y < panel.maxY - 30 else { break }
                Draw.line(ctx, wrapped, x: panel.minX + 44, baseline: y)
                y += size * 1.45
            }
        }
    }

    private func bench(_ ctx: CGContext, t: Double) {
        headline(ctx, "Fewer guesses.", sub: "“This” / “here” resolved to the right element", t: t, y: 200, size: 64)
        let rows: [(String, Double, String, CGColor)] = [
            ("Screenshot + text", 18.0 / 27, "67%  (18/27)", Draw.rgb(0xAEAEB2)),
            ("Yubisashi", 1.0, "100%  (27/27)", Draw.pink),
        ]
        for (i, row) in rows.enumerated() {
            let y = 430 + Double(i) * 150
            Draw.line(ctx, Draw.text(row.0, 30, .semibold, ink), x: 360, baseline: y)
            let full = 1000.0
            let grow = min(1, max(0, (t - 0.4 - Double(i) * 0.25) / 0.8))
            let e = grow * grow * (3 - 2 * grow)
            Draw.rrect(ctx, CGRect(x: 360, y: y + 22, width: full, height: 30), 15, fill: Draw.rgb(0xE5E5EA))
            Draw.rrect(ctx, CGRect(x: 360, y: y + 22, width: max(30, full * row.1 * e), height: 30), 15, fill: row.3)
            Draw.line(ctx, Draw.text(row.2, 28, .bold, ink), x: 1390, baseline: y + 47)
        }
        let note = Draw.text(
            "Our benchmark: 2 synthetic UI tasks, 6 runs per condition, Claude as the agent. Method and raw outputs on GitHub.",
            19, .regular, gray)
        Draw.centered(ctx, note, center: CGPoint(x: 960, y: 820))
    }

    private func end(_ ctx: CGContext, t: Double) {
        headline(ctx, "Yubisashi", sub: "Open source  ·  macOS 26  ·  Runs on-device", t: t, y: 450, size: 96)
        let a = min(1, max(0, (t - 0.5) / 0.5))
        ctx.saveGState()
        ctx.setAlpha(a)
        Draw.centered(ctx, Draw.text("github.com/sadakoa/yubisashi", 30, .semibold, Draw.pink), center: CGPoint(x: 960, y: 640))
        ctx.restoreGState()
    }

    // MARK: 文字

    /// 中央揃えの見出しと補足。最初の 0.5 秒で少し下から現れる
    private func headline(_ ctx: CGContext, _ title: String, sub: String?, t: Double, y: Double, size: Double) {
        let a = min(1, max(0, t / 0.5))
        let e = a * a * (3 - 2 * a)
        ctx.saveGState()
        ctx.setAlpha(e)
        Draw.centered(ctx, Draw.text(title, size, .bold, ink), center: CGPoint(x: 960, y: y + (1 - e) * 14))
        if let sub {
            Draw.centered(ctx, Draw.text(sub, size * 0.42, .regular, gray), center: CGPoint(x: 960, y: y + size * 0.95 + (1 - e) * 14))
        }
        ctx.restoreGState()
    }
}
