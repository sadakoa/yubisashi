import AppKit
import CoreText

/// 開発用: 「スクショ＋文章」と「Yubisashi の記録」を比べるための素材を作る。
/// `Yubisashi --eval-materials <出力先フォルダ>`
///
/// 題材ごとに次の2つを作る。
/// - A/: 画面のスクリーンショット（軌跡なし）と、書き起こした文章（音声入力＋スクショに相当）
/// - B/: Yubisashi の記録（review.md と画像）
enum EvalMaterials {
    static func run(dir: URL) async throws {
        let fm = FileManager.default
        // 指定されたフォルダそのものは消さない。作り直すのは、このコマンドが作るサブフォルダだけ
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for own in ["buttons", "dashboard", "_work-buttons", "_work-dashboard"] {
            try? fm.removeItem(at: dir.appendingPathComponent(own))
        }

        // 題材1: デモと同じ（ボタンの色、カード、戻るボタン）
        let buttons = try await ConceptVideo.record(
            work: dir.appendingPathComponent("_work-buttons"), lang: .ja,
            reviewDir: dir.appendingPathComponent("buttons/B"))
        try writeA(
            dir.appendingPathComponent("buttons/A"), screens: [buttons.screenList, buttons.screenDetail],
            output: buttons.output)

        // 題材2: 名前で呼びにくい指摘を含むダッシュボード
        let dash = try await Dashboard.record(
            work: dir.appendingPathComponent("_work-dashboard"),
            reviewDir: dir.appendingPathComponent("dashboard/B"))
        try writeA(dir.appendingPathComponent("dashboard/A"), screens: [dash.screen], output: dash.output)

        for work in ["_work-buttons", "_work-dashboard"] { try? fm.removeItem(at: dir.appendingPathComponent(work)) }
    }

    /// A: 記録と同じ大きさのスクリーンショットと、書き起こした文章
    private static func writeA(_ dir: URL, screens: [CGImage], output: ReviewBuilder.Output) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, screen) in screens.enumerated() {
            writeJPEG(
                ConceptVideo.scaled(screen, to: CGSize(width: 1600, height: 900)),
                to: dir.appendingPathComponent("screen-\(i + 1).jpg"), quality: 0.92)
        }
        let text = output.segments.filter(\.speech).map(\.plainText).joined(separator: "\n")
        try text.write(to: dir.appendingPathComponent("instruction.txt"), atomically: true, encoding: .utf8)
    }
}

/// 題材2: アナリティクスのダッシュボード
enum Dashboard {
    struct Recorded {
        var output: ReviewBuilder.Output
        var screen: CGImage
    }

    static let lines = [
        "この余白、こっちと同じにして。",
        "このアイコンだけ、少し大きい。",
        "このラベル、もう少し濃くしたい。",
        "タグの並び、ここだけ詰まってる。",
    ]
    static let words = ["この", "こっち", "この", "この", "ここ"]

    static let window = CGRect(x: 260, y: 70, width: 1400, height: 810)
    static let cardX = [320.0, 650.0, 980.0, 1310.0]
    static let cardInset = [24.0, 44.0, 24.0, 24.0]  // 2枚目だけ余白が広い
    static let iconSymbols = ["magnifyingglass", "bell", "tray", "calendar", "gearshape", "person.crop.circle"]
    static let iconSize = [22.0, 28.0, 22.0, 22.0, 22.0, 22.0]  // 2つ目だけ大きい
    static let labels = ["訪問者", "コンバージョン", "平均滞在", "直帰率"]
    static let values = ["12,480", "3.2%", "2分41秒", "38%"]
    static let deltas = ["+8%", "+0.4pt", "+12秒", "−3pt"]
    static let chips = ["すべて", "新規", "リピーター", "モバイル", "デスクトップ", "広告経由"]
    static let chipGaps = [16.0, 16.0, 5.0, 16.0, 16.0]  // リピーターとモバイルの間だけ詰まっている

    static func iconCenter(_ i: Int) -> CGPoint { CGPoint(x: 1350 + Double(i) * 50, y: 170) }

    static func chipRects() -> [CGRect] {
        var x = 320.0
        var rects: [CGRect] = []
        for (i, c) in chips.enumerated() {
            let w = Draw.width(Draw.text(c, 15, .medium, Draw.black)) + 32
            rects.append(CGRect(x: x, y: 740, width: w, height: 38))
            if i < chipGaps.count { x += w + chipGaps[i] }
        }
        return rects
    }

    static func record(work: URL, reviewDir: URL) async throws -> Recorded {
        L.override = .ja
        L.speechOverride = .ja
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let parts = try lines.enumerated().map { i, line in
            try ConceptVideo.say(line, voice: "Kyoko", to: work.appendingPathComponent("l\(i).wav"))
        }
        let voiceURL = work.appendingPathComponent("voice.wav")
        let samples = try ConceptVideo.combine(parts, gaps: [1.0, 1.6, 1.6, 1.6, 1.5], to: voiceURL)
        let duration = Double(samples.count) / 16000
        let chars = try await Transcriber.transcribe(url: voiceURL, language: .ja)
        let t = try ConceptVideo.wordTimes(words, in: chars, english: false)

        // 指す場所
        let card2Pad = CGPoint(x: cardX[1] + 20, y: 300)
        let card1Pad = CGPoint(x: cardX[0] + 11, y: 300)
        let bell = iconCenter(1)
        let labelW = Draw.width(Draw.text(labels[2], 16, .medium, Draw.black))
        let label3 = CGPoint(x: cardX[2] + cardInset[2] + labelW / 2, y: 264)
        let rects = chipRects()
        let gap = CGPoint(x: (rects[2].maxX + rects[3].minX) / 2, y: rects[2].midY)
        let chipStart = CGPoint(x: rects[0].minX + 12, y: rects[0].midY + 2)

        let keys: [(Double, CGPoint)] = [
            (0, CGPoint(x: 1000, y: 820)),
            (t[0] - 0.4, card2Pad), (t[0] + 0.65, card2Pad),
            (t[1] - 0.35, card1Pad), (t[1] + 0.65, card1Pad),
            (t[2] - 0.4, bell), (t[2] + 0.7, bell),
            (t[3] - 0.4, label3), (t[3] + 0.7, label3),
            // 「タグの並び」と言いながら、並びに沿ってなぞってから、詰まっている所で止まる
            (t[4] - 1.4, chipStart), (t[4] - 0.35, gap), (t[4] + 0.75, gap),
            (duration, CGPoint(x: gap.x + 20, y: gap.y + 90)),
        ]
        var cursor: [CursorSample] = []
        var time = 0.0
        while time <= duration {
            var p = keys.last!.1
            for k in 1..<keys.count where time <= keys[k].0 {
                let (ta, pa) = keys[k - 1]
                let (tb, pb) = keys[k]
                let u = max(0, min(1, (time - ta) / max(tb - ta, 0.01)))
                // なぞる区間は一定の速さ、それ以外はなめらかに加減速
                let tracing = pa == chipStart && pb == gap
                let e = tracing ? u : u * u * (3 - 2 * u)
                p = CGPoint(x: pa.x + (pb.x - pa.x) * e, y: pa.y + (pb.y - pa.y) * e)
                if pa == pb {
                    p.x += 1.2 * sin(time * 7.3)
                    p.y += 1.0 * cos(time * 5.1)
                }
                break
            }
            cursor.append(CursorSample(t: time, x: p.x, y: p.y, on: true))
            time += 1.0 / 60
        }

        let screen = render()
        let choreo = ConceptVideo.Choreo(samples: cursor, click: nil, clickPoint: .zero, transition: duration + 1)
        let output = try await ConceptVideo.buildReview(
            dir: reviewDir, screens: [(0, screen)], choreo: choreo, voiceURL: voiceURL, duration: duration, lang: .ja)
        return Recorded(output: output, screen: screen)
    }

    static func render() -> CGImage {
        let size = ConceptVideo.size
        let ctx = Draw.context(size)
        Draw.flip(ctx, height: size.height)
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [Draw.rgb(0x2B2F4A), Draw.rgb(0x4A3B5C)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        ctx.setFillColor(Draw.white.copy(alpha: 0.16)!)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 30))
        Draw.line(ctx, Draw.text("アナリティクス", 14, .semibold, Draw.white), x: 22, baseline: 20)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 44, color: Draw.black.copy(alpha: 0.4))
        Draw.rrect(ctx, window, 14, fill: Draw.white)
        ctx.restoreGState()
        ctx.setFillColor(Draw.rgb(0xF4F4F6))
        ctx.fill(CGRect(x: window.minX + 1, y: window.minY + 1, width: window.width - 2, height: 51))
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(Draw.rgb(c))
            ctx.fillEllipse(in: CGRect(x: window.minX + 22 + Double(i) * 22, y: window.minY + 19, width: 14, height: 14))
        }

        let ink = Draw.rgb(0x1C1C22)
        let sub = Draw.rgb(0x8A8A96)
        Draw.line(ctx, Draw.text("アナリティクス", 30, .bold, ink), x: 320, baseline: 184)
        for (i, name) in iconSymbols.enumerated() {
            let c = iconCenter(i)
            let s = iconSize[i]
            Draw.symbol(ctx, name, in: CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s), color: Draw.rgb(0x55555F))
        }
        for i in 0..<4 {
            let r = CGRect(x: cardX[i], y: 230, width: 300, height: 150)
            Draw.rrect(ctx, r, 14, fill: Draw.white, stroke: Draw.rgb(0xE2E2E8), lw: 1.5)
            let x = r.minX + cardInset[i]
            Draw.line(ctx, Draw.text(labels[i], 16, .medium, sub), x: x, baseline: 270)
            Draw.line(ctx, Draw.text(values[i], 36, .bold, ink), x: x, baseline: 325)
            Draw.line(ctx, Draw.text(deltas[i], 15, .medium, Draw.rgb(0x1E9E5A)), x: x, baseline: 358)
        }
        let chart = CGRect(x: 320, y: 410, width: 1290, height: 270)
        Draw.rrect(ctx, chart, 14, fill: Draw.white, stroke: Draw.rgb(0xE2E2E8), lw: 1.5)
        Draw.line(ctx, Draw.text("訪問者の推移", 16, .semibold, ink), x: chart.minX + 24, baseline: chart.minY + 36)
        for k in 0..<4 {
            ctx.setFillColor(Draw.rgb(0xF0F0F4))
            ctx.fill(CGRect(x: chart.minX + 24, y: chart.minY + 70 + Double(k) * 48, width: chart.width - 48, height: 1))
        }
        ctx.setStrokeColor(Draw.rgb(0x3B7AFF))
        ctx.setLineWidth(3)
        let ys = [210.0, 190, 200, 160, 170, 130, 140, 110, 120, 95, 100, 80]
        for (k, y) in ys.enumerated() {
            let p = CGPoint(x: chart.minX + 40 + Double(k) * 110, y: chart.minY + y)
            k == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
        }
        ctx.strokePath()

        Draw.line(ctx, Draw.text("フィルター", 16, .semibold, ink), x: 320, baseline: 726)
        for (i, r) in chipRects().enumerated() {
            Draw.rrect(ctx, r, 19, fill: i == 0 ? Draw.rgb(0x1C1C22) : Draw.rgb(0xF1F1F5))
            Draw.centered(ctx, Draw.text(chips[i], 15, .medium, i == 0 ? Draw.white : ink), center: CGPoint(x: r.midX, y: r.midY))
        }
        return ctx.makeImage()!
    }
}
