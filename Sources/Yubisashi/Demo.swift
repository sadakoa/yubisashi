import AVFoundation
import AppKit
import CoreText
import SwiftUI

/// 開発用: 合成した画面・音声・カーソルの動きから記録を作り、書き出しまでを通して確かめる。
/// `Yubisashi --demo <出力先フォルダ>`
enum Demo {
    static func run(outputRoot: URL) async throws -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let dir = outputRoot.appendingPathComponent("demo-" + fmt.string(from: Date()), isDirectory: true)
        let raw = dir.appendingPathComponent("frames_raw", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)

        // 1. 音声（Kyoko の読み上げ）
        let audioURL = dir.appendingPathComponent("audio.wav")
        let text =
            "このボタンの色を、こっちと揃えてほしい。[[slnc 1500]]それから、ここを押すと詳細に行くけど、戻るボタンがここにあるのは遠いです。"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kyoko", "-o", audioURL.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()

        let audioOffset = 0.5
        let chars = try await Transcriber.transcribe(url: audioURL, language: .ja).map {
            CharStamp(ch: $0.ch, start: $0.start + audioOffset, end: $0.end + audioOffset)
        }
        let duration = (chars.last?.end ?? 8) + 1.5

        // 2. 指示語の時刻に合わせて、カーソルの動きを作る
        let flat = chars.flatMap { s in Array(s.ch).map { (c: $0, t: s.start) } }
        let s = String(flat.map(\.c))
        var times: [Double] = []
        for word in ["この", "こっち", "ここ", "ここ"] {
            let searchStart = times.isEmpty ? s.startIndex : s.index(s.startIndex, offsetBy: indexAfter(times.last!, flat))
            if let r = s.range(of: word, range: searchStart..<s.endIndex) {
                times.append(flat[s.distance(from: s.startIndex, to: r.lowerBound)].t)
            }
        }
        guard times.count == 4 else { throw YubisashiError("デモ: 指示語が4つ見つかりませんでした: \(s)") }

        let save = CGPoint(x: 300, y: 330)
        let cancel = CGPoint(x: 560, y: 330)
        let card = CGPoint(x: 450, y: 600)
        let back = CGPoint(x: 70, y: 110)
        let clickT = times[2] + 0.4
        let transitionT = times[2] + 0.8

        var cursor: [CursorSample] = []
        var t = 0.0
        while t <= duration {
            let p = cursorPosition(
                t, times: times, save: save, cancel: cancel, card: card, back: back)
            cursor.append(CursorSample(t: t, x: p.x, y: p.y, on: true))
            t += 1.0 / 60
        }

        // 3. 画面（一覧画面 → 詳細画面）
        let size = CGSize(width: 1600, height: 1000)
        writeJPEG(listScreen(size), to: raw.appendingPathComponent("f00001.jpg"), quality: 0.92)
        writeJPEG(detailScreen(size), to: raw.appendingPathComponent("f00002.jpg"), quality: 0.92)

        let data = RecordingData(
            dir: dir, rawFramesDir: raw, startDate: Date(), duration: duration,
            displaySize: size, frameSize: size,
            frames: [
                FrameRecord(t: 0, file: "f00001.jpg", change: 1),
                FrameRecord(t: transitionT, file: "f00002.jpg", change: 0.8),
            ],
            transitions: [transitionT], cursor: cursor,
            clicks: [ClickEvent(t: clickT, x: card.x, y: card.y, button: "left")],
            scrolls: [], audioURL: audioURL, audioOffset: audioOffset, videoURL: nil, speechLanguage: .ja)
        let output = await ReviewBuilder.build(from: data)
        return output.markdownURL
    }

    private static func indexAfter(_ t: Double, _ flat: [(c: Character, t: Double)]) -> Int {
        (flat.firstIndex { $0.t > t + 0.05 } ?? flat.count)
    }

    /// 指示語の 0.3 秒前に目的の場所へ着き、0.6 秒とどまる。4つ目は戻るボタンの周りを囲む。
    private static func cursorPosition(
        _ t: Double, times: [Double], save: CGPoint, cancel: CGPoint, card: CGPoint, back: CGPoint
    ) -> CGPoint {
        let home = CGPoint(x: 900, y: 800)
        let keys: [(t: Double, p: CGPoint)] = [
            (0, home),
            (times[0] - 0.3, save), (times[0] + 0.6, save),
            (times[1] - 0.3, cancel), (times[1] + 0.6, cancel),
            (times[2] - 0.3, card), (times[2] + 0.9, card),
            (times[3] - 0.6, CGPoint(x: back.x + 45, y: back.y)),
        ]
        // 4つ目: 戻るボタンの周りを 1.4 秒かけて1周
        if t >= times[3] - 0.6 {
            let a = min(1, (t - (times[3] - 0.6)) / 1.4) * 2 * .pi
            return CGPoint(x: back.x + 45 * cos(a), y: back.y + 30 * sin(a))
        }
        for k in 1..<keys.count where t <= keys[k].t {
            let a = keys[k - 1]
            let b = keys[k]
            let u = max(0, min(1, (t - a.t) / max(b.t - a.t, 0.01)))
            let e = u * u * (3 - 2 * u)
            return CGPoint(x: a.p.x + (b.p.x - a.p.x) * e, y: a.p.y + (b.p.y - a.p.y) * e)
        }
        return keys.last!.p
    }

    // MARK: 画面の絵

    private static func canvas(_ size: CGSize, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 72))
        draw(ctx)
        return ctx.makeImage()!
    }

    private static func listScreen(_ size: CGSize) -> CGImage {
        canvas(size) { ctx in
            text(ctx, "プロジェクト一覧", at: CGPoint(x: 40, y: 46), size: 26, bold: true)
            box(ctx, CGRect(x: 220, y: 300, width: 160, height: 56), CGColor(srgbRed: 0.23, green: 0.48, blue: 1, alpha: 1))
            text(ctx, "保存", at: CGPoint(x: 278, y: 337), size: 20, color: .white, bold: true)
            box(ctx, CGRect(x: 480, y: 300, width: 160, height: 56), CGColor(srgbRed: 0.18, green: 0.42, blue: 0.92, alpha: 1))
            text(ctx, "キャンセル", at: CGPoint(x: 510, y: 337), size: 20, color: .white, bold: true)
            box(ctx, CGRect(x: 220, y: 460, width: 520, height: 260), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            text(ctx, "Q4 リニューアル", at: CGPoint(x: 250, y: 510), size: 24, bold: true)
            text(ctx, "最終更新 10月8日", at: CGPoint(x: 250, y: 550), size: 18)
        }
    }

    private static func detailScreen(_ size: CGSize) -> CGImage {
        canvas(size) { ctx in
            text(ctx, "‹ 戻る", at: CGPoint(x: 40, y: 118), size: 20, color: NSColor.systemBlue)
            text(ctx, "Q4 リニューアル", at: CGPoint(x: 600, y: 46), size: 26, bold: true)
            box(ctx, CGRect(x: 600, y: 200, width: 700, height: 500), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            text(ctx, "概要", at: CGPoint(x: 630, y: 250), size: 22, bold: true)
            text(ctx, "画面の情報設計を見直す。", at: CGPoint(x: 630, y: 300), size: 18)
        }
    }

    private static func box(_ ctx: CGContext, _ r: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 1))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.strokePath()
    }

    private static func text(
        _ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, color: NSColor = .black, bold: Bool = false
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

/// 開発用: 記録中の表示を画像に書き出す。`Yubisashi --overlay-snapshot <出力先フォルダ>`
@MainActor
enum OverlaySnapshot {
    static func run(dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 900, height: 560)

        // カーソル: 左下から右上へ曲線で動き、ボタンの上で止まる（声は途中で大きくなる）
        func snapshot(until stopT: Double, name: String) {
            let view = CursorOverlayView(frame: NSRect(origin: .zero, size: size))
            view.showBorderForSnapshot()
            var t = 0.0
            while t <= stopT {
                let u = min(1, t / 1.0)
                let e = u * u * (3 - 2 * u)
                let p = CGPoint(x: 140 + 520 * e, y: 120 + 260 * e + 90 * sin(e * .pi))
                let level = t > 0.6 ? 0.7 : 0.1
                view.update(point: p, onScreen: true, now: t, level: level)
                t += 1.0 / 60
            }
            let ctx = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CGColor(srgbRed: 0.23, green: 0.48, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 600, y: 352, width: 120, height: 44))
            view.layer!.render(in: ctx)
            writeJPEG(ctx.makeImage()!, to: dir.appendingPathComponent(name), quality: 0.9)
        }
        snapshot(until: 0.7, name: "cursor-moving.jpg")
        snapshot(until: 1.25, name: "cursor-dwelling.jpg")

        // 画面下の帯
        let phases: [(HUDModel.Phase, String)] = [
            (.starting, "hud-starting"), (.recording, "hud-recording"), (.processing, "hud-processing"),
            (.done("コピーしました", "エージェントに貼り付けてください"), "hud-done"),
        ]
        for (phase, name) in phases {
            let model = HUDModel()
            model.phase = phase
            model.elapsed = 42
            model.level = 0.6
            let renderer = ImageRenderer(content: HUDView(model: model).background(Color.gray))
            renderer.scale = 2
            if let img = renderer.cgImage {
                writeJPEG(img, to: dir.appendingPathComponent(name + ".jpg"), quality: 0.9)
            }
        }

        // 破棄の確認と、字幕
        let model = HUDModel()
        model.phase = .recording
        model.elapsed = 12
        model.level = 0.5
        model.confirmingDiscard = true
        model.captionFinal = "10月12日の月曜日が祝日だから、このあたりに"
        model.captionVolatile = "子供とご飯を食べる時間を"
        model.captionLanguage = .ja
        let view = VStack(spacing: 0) {
            CaptionView(model: model)
            HUDView(model: model)
        }.background(Color.gray)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.cgImage {
            writeJPEG(img, to: dir.appendingPathComponent("hud-caption.jpg"), quality: 0.9)
        }
    }
}

/// 開発用: 保存済みの timeline.json から解析だけをやり直して、区間と番号を表示する。
/// `Yubisashi --reanalyze <timeline.json>`
enum Reanalyze {
    private struct Saved: Decodable {
        var speechLanguage: Lang?
        var duration: Double
        var displaySize: [Double]
        var frameSize: [Double]
        var transcript: [CharStamp]
        var cursor: [CursorSample]
        var clicks: [ClickEvent]
        var scrolls: [Double]
        var transitions: [Double]
    }

    /// timeline.json と同じフォルダの audio.wav を、話す言語を自動判定して書き起こし直してから解析する
    static func runRetranscribing(_ url: URL) async throws {
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        let audio = url.deletingLastPathComponent().appendingPathComponent("audio.wav")
        let transcript = try await Transcriber.transcribeAuto(url: audio)
        let offset = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["audioOffset"] as? Double ?? 0
        print(String(format: "speech: %@ (confidence %.2f)", transcript.language.rawValue, transcript.confidence))
        try run(url, transcript: transcript.stamps.map { CharStamp(ch: $0.ch, start: $0.start + offset, end: $0.end + offset) }, language: transcript.language, saved: saved)
    }

    static func run(_ url: URL) throws {
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        try run(url, transcript: saved.transcript, language: saved.speechLanguage ?? .ja, saved: saved)
    }

    private static func run(_ url: URL, transcript: [CharStamp], language: Lang, saved: Saved) throws {
        let dir = url.deletingLastPathComponent()
        let data = RecordingData(
            dir: dir, rawFramesDir: dir, startDate: Date(), duration: saved.duration,
            displaySize: CGSize(width: saved.displaySize[0], height: saved.displaySize[1]),
            frameSize: CGSize(width: saved.frameSize[0], height: saved.frameSize[1]),
            frames: [], transitions: saved.transitions, cursor: saved.cursor, clicks: saved.clicks,
            scrolls: saved.scrolls, audioURL: dir, audioOffset: 0, videoURL: nil,
            speechLanguage: language)
        let s = data.pixelScale
        for seg in Analyzer(data: data, chars: transcript).run() {
            print("## \(seg.index). \(formatTime(seg.start))–\(formatTime(seg.end))")
            print(seg.speech ? "> \(seg.markedText)" : "> (no speech)")
            for a in seg.anchors {
                print(
                    "  \(circled(a.number)) \(formatTime(a.t)) \(ReviewBuilder.motionLabel(a, scale: s)) @ \(Int(a.x * s)),\(Int(a.y * s)) \(a.words)"
                )
            }
            for m in seg.moves { print("  move \(m.from)→\(m.to) \(m.kind.label) \(Int(m.length * s))px") }
        }
    }
}

/// 開発用: 音声ファイルをマイクの代わりに流して、その場の字幕を確かめる。`Yubisashi --caption-test <wav>`
enum CaptionTest {
    static func run(_ url: URL) async throws {
        let caption = LiveCaption(languages: Lang.allCases, preferred: .en)
        var last = ""
        caption.onUpdate = { state in
            let line = "[\(state.language.rawValue)] \(state.finalized)|\(state.volatile)"
            if line != last {
                print(line)
                last = line
            }
        }
        try await caption.startForTesting()
        let file = try AVAudioFile(forReading: url)
        let chunk: AVAudioFrameCount = 4096
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk)!
            try file.read(into: buffer, frameCount: chunk)
            caption.feedForTesting(buffer)
            // 実時間の4倍の速さで流す
            try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate / 4 * 1e9))
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        caption.stop()
    }
}
