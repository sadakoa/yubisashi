import AVFoundation
import AppKit
import CoreText
import WebKit

/// 開発用: 本物の Web ページと、本物の Claude Code の修正で作るデモ動画。
///
/// 1. `Yubisashi --real-demo-prepare <dir>`: <dir>/app のページを撮り、話しながら指した記録を作る（<dir>/review/review.md）
/// 2. review.md を Claude Code に渡して <dir>/app を直してもらい、返答・手順・差分を保存する
///    （<dir>/agent-output.md、<dir>/agent-steps.txt、<dir>/diff.txt）
/// 3. `Yubisashi --real-demo <dir>`: 直った後のページを撮り直し、動画を作る（<dir>/yubisashi-demo.mp4）
///
/// 作り物は、声（合成音声）とカーソルの動き（プログラム）だけ。
enum RealDemo {
    static let line = "Make this button's color match that one."

    struct Meta: Codable {
        var share: [Double]
        var export: [Double]
        var duration: Double
        var times: [Double]
        var samples: [CursorSample]
    }

    // MARK: 準備

    @MainActor
    static func prepare(dir: URL) async throws -> URL {
        let fm = FileManager.default
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. ページを撮り、ボタンの位置をページ自身から取る
        let shot = try await PageShot.make(appDir: dir.appendingPathComponent("app"))
        let before = try await shot.image()
        let share = try await shot.rect(".share")
        let export = try await shot.rect(".export")
        writePNG(before, to: work.appendingPathComponent("before.png"))

        // 2. 声
        let voice = try ConceptVideo.say(line, voice: "Samantha", to: work.appendingPathComponent("line.wav"))
        let voiceURL = work.appendingPathComponent("voice.wav")
        let samples = try ConceptVideo.combine([voice], gaps: [0.8, 1.2], to: voiceURL)
        let duration = Double(samples.count) / 16000
        let chars = try await Transcriber.transcribe(url: voiceURL, language: .en)
        let t = try ConceptVideo.wordTimes(["this", "that"], in: chars, english: true)

        // 3. カーソル: 「this」で Share、「that」で Export に止まる
        let start = CGPoint(x: 1180, y: 760)
        let a = CGPoint(x: share.midX + 4, y: share.midY + 2)
        let b = CGPoint(x: export.midX - 6, y: export.midY + 3)
        let keys: [(Double, CGPoint)] = [
            (0, start), (t[0] - 0.4, a), (t[0] + 0.65, a), (t[1] - 0.35, b), (t[1] + 0.7, b),
            (duration, CGPoint(x: b.x + 30, y: b.y + 140)),
        ]
        var cursor: [CursorSample] = []
        var time = 0.0
        while time <= duration {
            var p = keys.last!.1
            for k in 1..<keys.count where time <= keys[k].0 {
                let (ta, pa) = keys[k - 1]
                let (tb, pb) = keys[k]
                let u = max(0, min(1, (time - ta) / max(tb - ta, 0.01)))
                let e = u * u * (3 - 2 * u)
                let bow = sin(e * .pi) * 0.1
                p = CGPoint(x: pa.x + (pb.x - pa.x) * e - (pb.y - pa.y) * bow, y: pa.y + (pb.y - pa.y) * e + (pb.x - pa.x) * bow)
                if pa == pb {
                    p.x += 1.2 * sin(time * 7.3)
                    p.y += 1.0 * cos(time * 5.1)
                }
                break
            }
            cursor.append(CursorSample(t: time, x: p.x, y: p.y, on: true))
            time += 1.0 / 60
        }

        // 4. Yubisashi の書き出し処理で記録を作る
        let choreo = ConceptVideo.Choreo(samples: cursor, click: nil, clickPoint: .zero, transition: duration + 1)
        let output = try await ConceptVideo.buildReview(
            dir: dir.appendingPathComponent("review"), screens: [(0, before)], choreo: choreo, voiceURL: voiceURL,
            duration: duration, lang: .en)

        let meta = Meta(
            share: [share.minX, share.minY, share.width, share.height],
            export: [export.minX, export.minY, export.width, export.height], duration: duration, times: t,
            samples: cursor)
        try JSONEncoder().encode(meta).write(to: work.appendingPathComponent("meta.json"))
        return output.markdownURL
    }

    // MARK: 動画

    @MainActor
    static func render(dir: URL) async throws -> URL {
        let work = dir.appendingPathComponent("work")
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: work.appendingPathComponent("meta.json")))
        guard let before = loadImage(work.appendingPathComponent("before.png")) else {
            throw YubisashiError("before.png がありません。先に --real-demo-prepare を実行してください。")
        }
        let after = try await PageShot.make(appDir: dir.appendingPathComponent("app")).image()
        writePNG(after, to: work.appendingPathComponent("after.png"))

        func read(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        let reviewText = try String(contentsOf: dir.appendingPathComponent("review/review.md"), encoding: .utf8)
        let quote = reviewText.components(separatedBy: "\n").first { $0.hasPrefix("> ") && !$0.contains("To the agent") }?
            .dropFirst(2) ?? ""
        let film = RealFilm(
            before: before, after: after, meta: meta, quote: String(quote),
            steps: try read("agent-steps.txt").components(separatedBy: "\n").filter { !$0.isEmpty },
            diff: try read("diff.txt"), reply: try read("agent-output.md"))

        let silent = work.appendingPathComponent("video.mp4")
        try await film.write(to: silent)
        let out = dir.appendingPathComponent("yubisashi-demo.mp4")
        let sys = URL(fileURLWithPath: "/System/Library/Sounds")
        try await ConceptVideo.muxPublic(
            video: silent,
            sounds: [
                (work.appendingPathComponent("voice.wav"), film.recStart),
                (sys.appendingPathComponent("Tink.aiff"), film.recStart),
                (sys.appendingPathComponent("Pop.aiff"), film.recStop),
                (sys.appendingPathComponent("Glass.aiff"), film.copied),
            ], to: out)
        return out
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - ページの撮影

/// WebKit でページを 1920×1080 で開き、撮影する（画面の外に置いたウインドウで描かせる）
@MainActor
final class PageShot: NSObject, WKNavigationDelegate {
    private let window: NSWindow
    private let web: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    private init(size: CGSize) {
        window = NSWindow(
            contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: .borderless,
            backing: .buffered, defer: false)
        web = WKWebView(frame: CGRect(origin: .zero, size: size))
        super.init()
        web.navigationDelegate = self
        window.contentView = web
        window.orderFrontRegardless()
    }

    static func make(appDir: URL) async throws -> PageShot {
        let shot = PageShot(size: ConceptVideo.size)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            shot.loaded = c
            shot.web.loadFileURL(appDir.appendingPathComponent("index.html"), allowingReadAccessTo: appDir)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        return shot
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func rect(_ selector: String) async throws -> CGRect {
        let js = "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()"
        let v = (try await web.evaluateJavaScript(js) as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0, 0]
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    func image() async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        let img = try await web.takeSnapshot(configuration: config)
        var r = CGRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else {
            throw YubisashiError("ページを撮影できませんでした")
        }
        // 1920×1080 ちょうどにそろえる
        let ctx = Draw.context(ConceptVideo.size)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: ConceptVideo.size))
        return ctx.makeImage()!
    }
}

// MARK: - 動画

private struct RealFilm {
    let before: CGImage
    let after: CGImage
    let meta: RealDemo.Meta
    let quote: String
    let steps: [String]
    let diff: String
    let reply: String

    // 時間割（秒）
    let recStart = 1.0
    var recStop: Double { recStart + meta.duration }
    var copied: Double { recStop + 1.0 }
    var paste: Double { copied + 0.7 }
    var stepAt: Double { paste + 0.7 }
    var diffAt: Double { stepAt + Double(steps.count) * 0.45 + 0.2 }
    var replyAt: Double { diffAt + 1.0 }
    var swapAt: Double { replyAt + 0.5 }
    var total: Double { swapAt + 4.2 }

    let bg = Draw.rgb(0xF5F5F7)
    let ink = Draw.rgb(0x1D1D1F)
    let gray = Draw.rgb(0x6E6E73)
    let browser = CGRect(x: 48, y: 146, width: 1220, height: 46 + 1220 * 1080 / 1920)
    var page: CGRect { CGRect(x: browser.minX, y: browser.minY + 46, width: browser.width, height: browser.height - 46) }
    let terminal = CGRect(x: 1292, y: 146, width: 580, height: 46 + 1220 * 1080 / 1920)

    /// ページの拡大（1 = 等倍）。指している間と、直った直後はボタンのあたりに寄る
    func zoom(_ t: Double) -> Double {
        let zin = 2.1
        let pointStart = recStart + meta.times[0] - 1.0
        let pointEnd = recStart + meta.times[1] + 0.9
        func ramp(_ a: Double, _ b: Double) -> Double { ease((t - a) / (b - a)) }
        if t < swapAt - 0.2 {
            return 1 + (zin - 1) * (ramp(pointStart, pointStart + 0.6) - ramp(pointEnd, pointEnd + 0.6))
        }
        return 1 + (zin - 1) * ramp(swapAt - 0.2, swapAt + 0.4)
    }

    /// 寄るときの中心（Share と Export の間の少し下）
    var focus: CGPoint {
        CGPoint(x: (meta.share[0] + meta.export[0] + meta.export[2]) / 2, y: meta.share[1] + meta.share[3] / 2 + 70)
    }

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

        var sim = OverlaySim(samples: meta.samples)
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
            draw(ctx, t: t, sim: &sim)
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(ConceptVideo.fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? YubisashiError("writer did not complete") }
    }

    private func ease(_ x: Double) -> Double {
        let u = max(0, min(1, x))
        return u * u * (3 - 2 * u)
    }

    // MARK: 1コマ

    private func draw(_ ctx: CGContext, t: Double, sim: inout OverlaySim) {
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: ConceptVideo.size))

        Draw.centered(ctx, Draw.text("Yubisashi", 22, .semibold, Draw.pink), center: CGPoint(x: 960, y: 54))
        Draw.centered(ctx, Draw.text("Point at it. Say it. Paste it.", 46, .bold, ink), center: CGPoint(x: 960, y: 100))

        drawBrowser(ctx, t: t, sim: &sim)
        drawTerminal(ctx, t: t)
        drawCaption(ctx, t: t)
        drawHUD(ctx, t: t)
        drawKeys(ctx, t: t - (recStart - 0.45))
        drawKeys(ctx, t: t - (recStop - 0.35))

        let note = Draw.text(
            "A real web page and a real Claude Code run. Synthetic voice; the cursor is moved by a script.", 18, .regular, gray)
        Draw.line(ctx, note, x: browser.minX, baseline: 1034)
        let link = Draw.text("github.com/sadakoa/yubisashi", 20, .semibold, ink)
        Draw.line(ctx, link, x: terminal.maxX - Draw.width(link), baseline: 1034)

        // 最初と最後は背景色からフェード（繰り返し再生でつながるように）
        let a = max(0, 1 - t / 0.4, 1 - (total - t) / 0.5)
        if a > 0 {
            ctx.setFillColor(bg.copy(alpha: a)!)
            ctx.fill(CGRect(origin: .zero, size: ConceptVideo.size))
        }
    }

    private func window(_ ctx: CGContext, _ r: CGRect, title: String) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 44, color: Draw.black.copy(alpha: 0.14))
        Draw.rrect(ctx, r, 16, fill: Draw.white)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.clip()
        ctx.setFillColor(Draw.rgb(0xF2F2F4))
        ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 46))
        ctx.setFillColor(Draw.rgb(0xE5E5EA))
        ctx.fill(CGRect(x: r.minX, y: r.minY + 45, width: r.width, height: 1))
        ctx.restoreGState()
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Draw.rgb(c))
            ctx.fillEllipse(in: CGRect(x: r.minX + 18 + Double(i) * 20, y: r.minY + 17, width: 12, height: 12))
        }
        let label = Draw.text(title, 15, .medium, gray)
        let pill = CGRect(x: r.midX - (Draw.width(label) + 40) / 2, y: r.minY + 10, width: Draw.width(label) + 40, height: 26)
        Draw.rrect(ctx, pill, 8, fill: Draw.white, stroke: Draw.rgb(0xE5E5EA), lw: 1)
        Draw.centered(ctx, label, center: CGPoint(x: pill.midX, y: pill.midY))
    }

    // MARK: 左: ブラウザ

    private func drawBrowser(_ ctx: CGContext, t: Double, sim: inout OverlaySim) {
        window(ctx, browser, title: "localhost:3000")
        let s = page.width / ConceptVideo.size.width
        let rt = t - recStart

        ctx.saveGState()
        ctx.addPath(CGPath(rect: page, transform: nil))
        ctx.clip()
        // 寄るときは、寄る中心がページの中央に来るように動かす（端に余白が出ないように抑える）
        let z = zoom(t)
        let k = s * z
        let progress = (z - 1) / 1.1
        let target = CGPoint(
            x: focus.x * s + (page.width / 2 - focus.x * s) * progress,
            y: focus.y * s + (page.height / 2 - focus.y * s) * progress)
        var ox = target.x - focus.x * k
        var oy = target.y - focus.y * k
        ox = min(0, max(page.width - ConceptVideo.size.width * k, ox))
        oy = min(0, max(page.height - ConceptVideo.size.height * k, oy))
        ctx.translateBy(x: page.minX + ox, y: page.minY + oy)
        ctx.scaleBy(x: k, y: k)
        let full = CGRect(origin: .zero, size: ConceptVideo.size)
        Draw.image(ctx, before, in: full)
        // 直った後のページに入れ替える
        if t >= swapAt {
            ctx.saveGState()
            ctx.setAlpha(ease((t - swapAt) / 0.35))
            Draw.image(ctx, after, in: full)
            ctx.restoreGState()
            // 変わったボタンを一瞬だけ示す
            let k = (t - swapAt) / 1.2
            if k < 1 {
                let r = CGRect(x: meta.share[0], y: meta.share[1], width: meta.share[2], height: meta.share[3])
                    .insetBy(dx: -10 - 14 * k, dy: -10 - 14 * k)
                ctx.setStrokeColor(Draw.pink.copy(alpha: 1 - k)!)
                ctx.setLineWidth(6)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
                ctx.strokePath()
            }
        }

        // 記録中の表示（Yubisashi と同じ見た目）
        let recording = rt >= 0 && rt <= meta.duration
        if recording {
            sim.advance(to: rt)
            sim.draw(ctx, now: rt, level: level(rt), clicks: [])
        }
        // カーソル
        let ct = max(0, min(meta.duration, rt))
        let p = OverlaySim.position(meta.samples, ct)
        arrow(ctx, at: p)
        ctx.restoreGState()

        // 記録中の枠は、拡大に関係なく画面（ページの表示領域）の縁に出す
        if recording {
            let intro = ease(rt / 0.4)
            ctx.saveGState()
            ctx.setAlpha(rt < 0.4 ? intro : 0.72 + 0.28 * cos((rt - 0.4) * .pi / 1.6))
            ctx.setShadow(offset: .zero, blur: 12, color: Draw.pink)
            ctx.setStrokeColor(Draw.pink)
            ctx.setLineWidth(7 - 3.5 * intro)
            ctx.stroke(page.insetBy(dx: 2, dy: 2))
            ctx.restoreGState()
        }
    }

    /// 声の大きさのかわりに、話している間だけ少し大きくする
    private func level(_ rt: Double) -> Double {
        let speaking = rt > meta.times[0] - 0.3 && rt < meta.times[1] + 0.6
        return speaking ? 0.45 + 0.25 * max(0, sin(rt * 9)) : 0.05
    }

    private func arrow(_ ctx: CGContext, at p: CGPoint) {
        let k = 1.9
        let pts: [(Double, Double)] = [(0, 21), (5, 16.2), (8.6, 23.6), (11.6, 22.3), (8.1, 15.1), (15, 15.1)]
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 6, color: Draw.black.copy(alpha: 0.35))
        ctx.move(to: p)
        for q in pts { ctx.addLine(to: CGPoint(x: p.x + q.0 * k, y: p.y + q.1 * k)) }
        ctx.closePath()
        ctx.setFillColor(Draw.black)
        ctx.setStrokeColor(Draw.white)
        ctx.setLineWidth(2.6)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    // MARK: 字幕と帯（Yubisashi の表示を、動画で読める大きさで）

    private func drawCaption(_ ctx: CGContext, t: Double) {
        let rt = t - recStart
        guard rt <= meta.duration else { return }
        // 単語ごとに出す（this / that はピンク）
        // 書き起こしで取れた「this」「that」の時刻に合わせて、単語を出す
        let words = RealDemo.line.components(separatedBy: " ")
        let iThis = words.firstIndex { $0.lowercased().hasPrefix("this") } ?? 1
        let iThat = words.firstIndex { $0.lowercased().hasPrefix("that") } ?? 5
        func revealAt(_ i: Int) -> Double {
            if i <= iThis { return meta.times[0] - 0.25 * Double(iThis - i) }
            if i <= iThat { return meta.times[0] + (meta.times[1] - meta.times[0]) * Double(i - iThis) / Double(iThat - iThis) }
            return meta.times[1] + 0.25 * Double(i - iThat)
        }
        let shown = words.indices.filter { revealAt($0) <= rt }.count
        guard shown > 0 else { return }
        let text = NSMutableAttributedString()
        for (i, wd) in words.prefix(shown).enumerated() {
            let bare = wd.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let pointing = bare == "this" || bare == "that"
            text.append(Draw.text((i > 0 ? " " : "") + wd, 26, pointing ? .bold : .medium, pointing ? Draw.pink : Draw.white))
        }
        let w = Draw.width(text) + 120
        let box = CGRect(x: page.midX - w / 2, y: page.maxY - 156, width: w, height: 56)
        Draw.rrect(ctx, box, 16, fill: Draw.rgb(0x111114).copy(alpha: 0.86)!)
        Draw.symbol(ctx, "mic.fill", in: CGRect(x: box.minX + 20, y: box.midY - 12, width: 20, height: 24), color: Draw.pink)
        Draw.line(ctx, text, x: box.minX + 54, baseline: box.midY + 9)
        let lang = Draw.text("English", 14, .medium, Draw.white.copy(alpha: 0.45)!)
        Draw.line(ctx, lang, x: box.maxX - 16 - Draw.width(lang), baseline: box.midY + 5)
    }

    private func drawHUD(_ ctx: CGContext, t: Double) {
        guard t >= recStart - 0.3, t <= copied + 1.6 else { return }
        let fade = t > copied + 1.3 ? 1 - (t - copied - 1.3) / 0.3 : 1
        let fs = 18.0
        var parts: [NSAttributedString] = []
        var lead: CGColor?
        if t < recStart {
            parts = [Draw.text("Starting…", fs, .medium, Draw.white)]
        } else if t < recStop {
            lead = Draw.rgb(0xFF3B30)
            parts = [
                Draw.text("Recording  ", fs, .medium, Draw.white),
                Draw.text(formatTime(t - recStart), fs, .medium, Draw.white.copy(alpha: 0.6)!),
                Draw.text("    ⌃⌥R to stop", fs, .medium, Draw.white.copy(alpha: 0.6)!),
            ]
        } else if t < copied {
            parts = [Draw.text("Exporting…", fs, .medium, Draw.white)]
        } else {
            lead = Draw.rgb(0x30D158)
            parts = [
                Draw.text("Copied  ", fs, .semibold, Draw.white),
                Draw.text("Paste into Claude Code or another coding agent", fs, .medium, Draw.white.copy(alpha: 0.6)!),
            ]
        }
        let text = NSMutableAttributedString()
        parts.forEach { text.append($0) }
        let w = Draw.width(text) + (lead == nil ? 48 : 72)
        let box = CGRect(x: page.midX - w / 2, y: page.maxY - 78, width: w, height: 48)
        ctx.saveGState()
        ctx.setAlpha(fade)
        Draw.rrect(ctx, box, 24, fill: Draw.rgb(0x111114).copy(alpha: 0.9)!)
        var x = box.minX + 24
        if let lead {
            ctx.setFillColor(lead)
            ctx.fillEllipse(in: CGRect(x: x, y: box.midY - 6, width: 12, height: 12))
            x += 24
        }
        Draw.line(ctx, text, x: x, baseline: box.midY + 6.5)
        ctx.restoreGState()
    }

    private func drawKeys(_ ctx: CGContext, t: Double) {
        guard t >= 0, t <= 1.0 else { return }
        let a = t < 0.12 ? t / 0.12 : (t > 0.75 ? (1.0 - t) / 0.25 : 1)
        ctx.saveGState()
        ctx.setAlpha(a)
        var x = browser.midX - (3 * 56 + 2 * 10) / 2.0
        for key in ["⌃", "⌥", "R"] {
            let r = CGRect(x: x, y: browser.maxY + 26, width: 56, height: 56)
            Draw.rrect(ctx, r.offsetBy(dx: 0, dy: 3), 11, fill: Draw.rgb(0xC7C7CC))
            Draw.rrect(ctx, r, 11, fill: Draw.white, stroke: Draw.rgb(0xD1D1D6), lw: 1)
            Draw.centered(ctx, Draw.text(key, 26, .semibold, ink), center: CGPoint(x: r.midX, y: r.midY))
            x += 66
        }
        ctx.restoreGState()
    }

    // MARK: 右: Claude Code

    private func drawTerminal(_ ctx: CGContext, t: Double) {
        window(ctx, terminal, title: "Claude Code — ~/app")
        let x = terminal.minX + 28
        let maxW = terminal.width - 56
        var y = terminal.minY + 46 + 44
        let mono = 18.5

        if t < paste {
            Draw.line(ctx, Draw.text("›", mono + 2, .bold, Draw.pink, mono: true), x: x, baseline: y)
            if Int(t * 2) % 2 == 0 {
                ctx.setFillColor(ink)
                ctx.fill(CGRect(x: x + 20, y: y - 16, width: 10, height: 20))
            }
            return
        }

        // 貼り付けた review.md（実際の記録の発話）
        let prompt = NSMutableAttributedString(attributedString: Draw.text("› ", mono + 2, .bold, Draw.pink, mono: true))
        prompt.append(Draw.text("[pasted review.md]", mono, .regular, gray, mono: true))
        Draw.line(ctx, prompt, x: x, baseline: y)
        y += 32
        let q = NSMutableAttributedString(attributedString: Draw.text("  “", 21, .regular, ink))
        for ch in quote {
            let n = (0x2460...0x2473).contains(ch.unicodeScalars.first!.value)
            q.append(Draw.text(String(ch), 21, n ? .bold : .regular, n ? Draw.pink : ink))
        }
        q.append(Draw.text("”", 21, .regular, ink))
        for line in Draw.wrap(q, width: maxW) {
            Draw.line(ctx, line, x: x, baseline: y)
            y += 30
        }
        y += 18

        // エージェントが実際に行った手順
        for (i, step) in steps.enumerated() where t >= stepAt + Double(i) * 0.45 {
            let row = NSMutableAttributedString(attributedString: Draw.text("⏺ ", mono, .bold, Draw.rgb(0x30A46C), mono: true))
            row.append(Draw.text(step, mono, .regular, ink, mono: true))
            Draw.line(ctx, row, x: x, baseline: y)
            y += 31
        }
        guard t >= diffAt else { return }
        y += 8

        // 実際の差分（- / + の行だけ）
        let changed = diff.components(separatedBy: "\n").filter {
            ($0.hasPrefix("-") || $0.hasPrefix("+")) && !$0.hasPrefix("---") && !$0.hasPrefix("+++")
        }
        for line in changed {
            let added = line.hasPrefix("+")
            let band = CGRect(x: x - 8, y: y - 23, width: maxW + 16, height: 33)
            ctx.setFillColor(added ? Draw.rgb(0xE3F6EA) : Draw.rgb(0xFDE7E7))
            ctx.fill(band)
            let text = line.replacingOccurrences(of: "\t", with: "  ")
            Draw.line(ctx, Draw.text(text, mono, .regular, added ? Draw.rgb(0x1E7B45) : Draw.rgb(0xB42318), mono: true), x: x, baseline: y)
            y += 33
        }
        guard t >= replyAt else { return }
        y += 20

        // 実際の返答（最初の段落）
        let first = reply.components(separatedBy: "\n\n").first?.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "") ?? ""
        let shown = String(first.prefix(Int((t - replyAt) * 160)))
        for line in Draw.wrap(Draw.text(shown, 22, .semibold, ink), width: maxW) {
            guard y < terminal.maxY - 20 else { break }
            Draw.line(ctx, line, x: x, baseline: y)
            y += 31
        }
    }
}
