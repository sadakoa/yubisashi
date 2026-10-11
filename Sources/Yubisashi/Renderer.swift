import AppKit
import CoreText

/// コマ画像に、カーソルの軌跡・番号・クリック位置を描き込む
struct Renderer {
    /// ポイント → ピクセル
    let scale: Double

    private let deep = CGColor(srgbRed: 0.88, green: 0.0, blue: 0.44, alpha: 1)  // #E00070
    private let light = CGColor(srgbRed: 1.0, green: 0.70, blue: 0.85, alpha: 1)  // #FFB3D9
    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    func render(
        base: CGImage, samples: [CursorSample], start: Double, end: Double, anchors: [Anchor],
        clicks: [ClickEvent], label: String, to url: URL
    ) {
        let w = base.width
        let h = base.height
        let u = CGFloat(w) / 1600
        // 画面の下に凡例の帯を足す。画面の中身を隠さず、座標も画面の左上からのままになる
        let strip = Int(44 * u)
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h + strip, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(base, in: CGRect(x: 0, y: strip, width: w, height: h))
        // ここから左上原点で描く
        ctx.translateBy(x: 0, y: CGFloat(h + strip))
        ctx.scaleBy(x: 1, y: -1)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
        drawPath(ctx, samples: samples, start: start, end: end, u: u)
        for c in clicks { drawClick(ctx, at: point(c.x, c.y), u: u) }
        for a in anchors { drawAnchor(ctx, a, u: u) }
        ctx.restoreGState()
        drawStrip(ctx, label, rect: CGRect(x: 0, y: h, width: w, height: strip), u: u)

        if let image = ctx.makeImage() { writeJPEG(image, to: url, quality: 0.88) }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

    /// 指した位置のまわりを切り抜いて 2 倍に拡大する。対象を隠さないよう、印は外側の角かっこと、隅の番号だけ。
    /// UI 要素の枠がわかっているときは、その枠を細い点線で囲む
    func closeUp(base: CGImage, anchor a: Anchor) -> CGImage? {
        let p = point(a.x, a.y)
        let r = max(26, CGFloat(a.radius * scale) + 10)
        let cropW = max(300, r * 2 + 120)
        let cropH = max(190, r * 2 + 80)
        let crop = CGRect(x: p.x - cropW / 2, y: p.y - cropH / 2, width: cropW, height: cropH)
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height)).integral
        guard crop.width > 10, crop.height > 10, let piece = base.cropping(to: crop) else { return nil }

        let zoom: CGFloat = 2
        let w = Int(crop.width * zoom)
        let h = Int(crop.height * zoom)
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // UI 要素の枠
        if let f = a.element?.frame, f.count == 4 {
            let rect = CGRect(
                x: (CGFloat(f[0]) * CGFloat(scale) - crop.minX) * zoom, y: (CGFloat(f[1]) * CGFloat(scale) - crop.minY) * zoom,
                width: CGFloat(f[2]) * CGFloat(scale) * zoom, height: CGFloat(f[3]) * CGFloat(scale) * zoom
            ).insetBy(dx: -3, dy: -3)
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.setStrokeColor(deep)
            ctx.setLineWidth(2)
            ctx.stroke(rect)
            ctx.restoreGState()
        }

        // 枠の中心 = 指した位置（拡大後の座標）
        let c = CGPoint(x: (p.x - crop.minX) * zoom, y: (p.y - crop.minY) * zoom)
        let half = r * zoom
        let arm = min(18 * zoom, half * 0.6)
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let corner = CGPoint(x: c.x + sx * half, y: c.y + sy * half)
            for color in [white, deep] {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(color == white ? 7 : 3)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: corner.x - sx * arm, y: corner.y))
                ctx.addLine(to: corner)
                ctx.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * arm))
                ctx.strokePath()
            }
        }
        // 番号は左上の隅に置く
        let badge = CGPoint(x: 26, y: 26)
        ctx.setFillColor(deep)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(3)
        ctx.addEllipse(in: CGRect(x: badge.x - 18, y: badge.y - 18, width: 36, height: 36))
        ctx.drawPath(using: .fillStroke)
        drawText(ctx, "\(a.number)", font: NSFont.systemFont(ofSize: 20, weight: .bold) as CTFont, color: white, center: badge)
        return ctx.makeImage()
    }

    /// 区間のクローズアップを1枚にまとめる（2列。読む画像の数を減らすため）
    func closeUpSheet(_ tiles: [CGImage], to url: URL) {
        guard !tiles.isEmpty else { return }
        let cols = min(2, tiles.count)
        let cellW = 620
        let gap = 12
        let scaled = tiles.map { t -> (CGImage, Int) in
            let h = Int(Double(t.height) * Double(cellW) / Double(t.width))
            return (t, h)
        }
        let rows = stride(from: 0, to: scaled.count, by: cols).map { Array(scaled[$0..<min(scaled.count, $0 + cols)]) }
        let rowHeights = rows.map { $0.map(\.1).max() ?? 0 }
        let width = cols * cellW + (cols + 1) * gap
        let height = rowHeights.reduce(0, +) + (rows.count + 1) * gap
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var top = gap
        for (r, row) in rows.enumerated() {
            for (c, tile) in row.enumerated() {
                let x = gap + c * (cellW + gap)
                // CGContext は左下原点なので、上からの位置を変換する
                ctx.draw(tile.0, in: CGRect(x: x, y: height - top - tile.1, width: cellW, height: tile.1))
            }
            top += rowHeights[r] + gap
        }
        if let image = ctx.makeImage() { writeJPEG(image, to: url, quality: 0.88) }
    }

    // MARK: 軌跡

    private func drawPath(_ ctx: CGContext, samples: [CursorSample], start: Double, end: Double, u: CGFloat) {
        // 画面外に出たところで線を切る
        var runs: [[CursorSample]] = [[]]
        for s in samples {
            if s.on {
                if let last = runs[runs.count - 1].last, hypot((s.x - last.x) * scale, (s.y - last.y) * scale) < 2 {
                    continue
                }
                runs[runs.count - 1].append(s)
            } else if !runs[runs.count - 1].isEmpty {
                runs.append([])
            }
        }
        runs = runs.filter { $0.count >= 2 }
        guard !runs.isEmpty else { return }

        let duration = max(end - start, 0.01)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        struct Piece {
            var a: CGPoint
            var b: CGPoint
            var fast: Bool
            var progress: CGFloat
        }
        var pieces: [Piece] = []
        for run in runs {
            for (p, q) in zip(run, run.dropFirst()) {
                let speed = hypot(q.x - p.x, q.y - p.y) / max(q.t - p.t, 0.001)
                pieces.append(
                    Piece(
                        a: point(p.x, p.y), b: point(q.x, q.y), fast: speed > 1400,
                        progress: CGFloat(min(1, max(0, (q.t - start) / duration)))))
            }
        }

        // 白いふちどり → 色の線の順に描く
        ctx.setStrokeColor(white.copy(alpha: 0.9)!)
        for p in pieces where !p.fast {
            ctx.setLineWidth(9 * u)
            ctx.move(to: p.a)
            ctx.addLine(to: p.b)
            ctx.strokePath()
        }
        for p in pieces where !p.fast {
            ctx.setStrokeColor(mix(light, deep, p.progress))
            ctx.setLineWidth(5 * u)
            ctx.move(to: p.a)
            ctx.addLine(to: p.b)
            ctx.strokePath()
        }
        // 素早い移動は細い点線
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [6 * u, 6 * u])
        ctx.setLineWidth(2 * u)
        ctx.setStrokeColor(deep.copy(alpha: 0.55)!)
        var i = 0
        while i < pieces.count {
            guard pieces[i].fast else {
                i += 1
                continue
            }
            ctx.move(to: pieces[i].a)
            while i < pieces.count, pieces[i].fast {
                ctx.addLine(to: pieces[i].b)
                i += 1
            }
            ctx.strokePath()
        }
        ctx.restoreGState()

        // 始点の○と終点の矢印
        let first = runs.first!.first!
        let startPoint = point(first.x, first.y)
        ctx.setFillColor(white)
        ctx.setStrokeColor(deep)
        ctx.setLineWidth(3 * u)
        ctx.addEllipse(in: CGRect(x: startPoint.x - 6 * u, y: startPoint.y - 6 * u, width: 12 * u, height: 12 * u))
        ctx.drawPath(using: .fillStroke)

        let last = runs.last!
        let tip = point(last.last!.x, last.last!.y)
        if let from = last.reversed().first(where: { hypot(point($0.x, $0.y).x - tip.x, point($0.x, $0.y).y - tip.y) > 14 * u }) {
            let fp = point(from.x, from.y)
            let angle = atan2(tip.y - fp.y, tip.x - fp.x)
            let size = 16 * u
            let left = CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7))
            let right = CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7))
            ctx.setStrokeColor(white)
            ctx.setLineWidth(3 * u)
            ctx.setFillColor(deep)
            ctx.move(to: tip)
            ctx.addLine(to: left)
            ctx.addLine(to: right)
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
        }
    }

    // MARK: 印

    private func drawClick(_ ctx: CGContext, at p: CGPoint, u: CGFloat) {
        let r = 13 * u
        ctx.setStrokeColor(white)
        ctx.setLineWidth(7 * u)
        ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
        ctx.setStrokeColor(deep)
        ctx.setLineWidth(3 * u)
        ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
    }

    /// 指した位置に小さな点、その右上に番号のバッジを置く（指した所を隠さないため）
    private func drawAnchor(_ ctx: CGContext, _ a: Anchor, u: CGFloat) {
        let p = point(a.x, a.y)
        if a.kind == .circle || a.kind == .area {
            let r = CGFloat(a.radius * scale) + 6 * u
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [8 * u, 5 * u])
            ctx.setStrokeColor(deep)
            ctx.setLineWidth(2.5 * u)
            ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.strokePath()
            ctx.restoreGState()
        }

        let dot = 5 * u
        ctx.setFillColor(deep)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(2.5 * u)
        ctx.addEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
        ctx.drawPath(using: .fillStroke)

        let badgeR = 15 * u
        let c = CGPoint(x: p.x + 20 * u, y: p.y - 20 * u)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(5 * u)
        ctx.move(to: p)
        ctx.addLine(to: c)
        ctx.strokePath()
        ctx.setStrokeColor(deep)
        ctx.setLineWidth(2 * u)
        ctx.move(to: p)
        ctx.addLine(to: c)
        ctx.strokePath()

        ctx.setFillColor(deep)
        ctx.setStrokeColor(white)
        ctx.setLineWidth(3 * u)
        ctx.addEllipse(in: CGRect(x: c.x - badgeR, y: c.y - badgeR, width: badgeR * 2, height: badgeR * 2))
        ctx.drawPath(using: .fillStroke)

        let font = NSFont.systemFont(ofSize: 17 * u, weight: .bold) as CTFont
        drawText(ctx, "\(a.number)", font: font, color: white, center: c)
    }

    /// 下の帯: 左に区間の番号と時間、右に凡例
    private func drawStrip(_ ctx: CGContext, _ text: String, rect: CGRect, u: CGFloat) {
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(rect)
        let midY = rect.midY
        let labelFont = NSFont.systemFont(ofSize: 18 * u, weight: .semibold) as CTFont
        let label = makeLine(text, font: labelFont, color: white)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(label, &ascent, &descent, nil)
        drawLine(ctx, label, x: 16 * u, baseline: midY + (ascent - descent) / 2)

        // 凡例は右端から左へ並べる
        let font = NSFont.systemFont(ofSize: 14 * u, weight: .regular) as CTFont
        let grey = CGColor(srgbRed: 0.82, green: 0.82, blue: 0.85, alpha: 1)
        var x = rect.maxX - 16 * u
        func legend(_ text: String, icon: (CGPoint) -> Void) {
            let line = makeLine(text, font: font, color: grey)
            var a: CGFloat = 0
            var d: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &a, &d, nil))
            x -= width
            drawLine(ctx, line, x: x, baseline: midY + (a - d) / 2)
            x -= 30 * u
            icon(CGPoint(x: x + 12 * u, y: midY))
            x -= 18 * u
        }
        legend(L.s("素早い移動", "Fast move")) { p in
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [4 * u, 4 * u])
            ctx.setLineWidth(2 * u)
            ctx.setStrokeColor(deep)
            ctx.move(to: CGPoint(x: p.x - 12 * u, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x + 12 * u, y: p.y))
            ctx.strokePath()
            ctx.restoreGState()
        }
        legend(L.s("軌跡（薄→濃が時間順）", "Path (light → dark over time)")) { p in
            ctx.setLineWidth(5 * u)
            ctx.setLineCap(.round)
            for k in 0..<6 {
                ctx.setStrokeColor(mix(light, deep, CGFloat(k) / 5))
                ctx.move(to: CGPoint(x: p.x - 12 * u + CGFloat(k) * 4 * u, y: p.y))
                ctx.addLine(to: CGPoint(x: p.x - 8 * u + CGFloat(k) * 4 * u, y: p.y))
                ctx.strokePath()
            }
        }
        legend(L.s("終点", "End")) { p in
            ctx.setFillColor(deep)
            ctx.move(to: CGPoint(x: p.x + 8 * u, y: p.y))
            ctx.addLine(to: CGPoint(x: p.x - 6 * u, y: p.y - 7 * u))
            ctx.addLine(to: CGPoint(x: p.x - 6 * u, y: p.y + 7 * u))
            ctx.closePath()
            ctx.fillPath()
        }
        legend(L.s("始点", "Start")) { p in
            ctx.setFillColor(white)
            ctx.setStrokeColor(deep)
            ctx.setLineWidth(3 * u)
            ctx.addEllipse(in: CGRect(x: p.x - 6 * u, y: p.y - 6 * u, width: 12 * u, height: 12 * u))
            ctx.drawPath(using: .fillStroke)
        }
        legend(L.s("指した位置", "Pointed spot")) { p in
            ctx.setFillColor(deep)
            ctx.setStrokeColor(white)
            ctx.setLineWidth(2 * u)
            ctx.addEllipse(in: CGRect(x: p.x - 11 * u, y: p.y - 11 * u, width: 22 * u, height: 22 * u))
            ctx.drawPath(using: .fillStroke)
            drawText(ctx, "1", font: NSFont.systemFont(ofSize: 13 * u, weight: .bold) as CTFont, color: white, center: p)
        }
    }

    // MARK: 文字

    private func makeLine(_ s: String, font: CTFont, color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    private func drawText(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor, center: CGPoint) {
        let line = makeLine(s, font: font, color: color)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        drawLine(ctx, line, x: center.x - width / 2, baseline: center.y + (ascent - descent) / 2)
    }

    private func drawLine(_ ctx: CGContext, _ line: CTLine, x: CGFloat, baseline: CGFloat) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let ca = a.components ?? [0, 0, 0, 1]
        let cb = b.components ?? [0, 0, 0, 1]
        return CGColor(
            srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
            blue: ca[2] + (cb[2] - ca[2]) * t, alpha: 1)
    }
}

/// 指した点の色と、その周り（半径 radius px）でいちばん多い色を返す（sRGB, #RRGGBB）。
/// 文字の上を指しても、ボタンなどの地の色がわかるようにするため。
func sampleColors(_ image: CGImage, x: Double, y: Double, radius: Int = 12) -> (point: String, around: String)? {
    let px = Int(x.rounded(.down))
    let py = Int(y.rounded(.down))
    guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }
    let rect = CGRect(x: px - radius, y: py - radius, width: radius * 2 + 1, height: radius * 2 + 1)
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let crop = image.cropping(to: rect) else { return nil }
    let w = Int(rect.width)
    let h = Int(rect.height)
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
        guard
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }

    // バッファは上の行から並ぶ
    let cx = px - Int(rect.minX)
    let cy = py - Int(rect.minY)
    let i = (cy * w + cx) * 4
    let point = String(format: "#%02X%02X%02X", pixels[i], pixels[i + 1], pixels[i + 2])

    // 各チャンネルを 16 段階に丸めて数え、いちばん多い組の平均を取る
    var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
    for k in stride(from: 0, to: pixels.count, by: 4) {
        let key = Int(pixels[k] >> 4) << 8 | Int(pixels[k + 1] >> 4) << 4 | Int(pixels[k + 2] >> 4)
        let v = buckets[key] ?? (0, 0, 0, 0)
        buckets[key] = (v.count + 1, v.r + Int(pixels[k]), v.g + Int(pixels[k + 1]), v.b + Int(pixels[k + 2]))
    }
    guard let top = buckets.values.max(by: { $0.count < $1.count }) else { return (point, point) }
    let around = String(format: "#%02X%02X%02X", top.r / top.count, top.g / top.count, top.b / top.count)
    return (point, around)
}

/// 2つの色がはっきり違うか
func colorsDiffer(_ a: String, _ b: String) -> Bool {
    func rgb(_ s: String) -> [Int] {
        let v = Int(s.dropFirst(), radix: 16) ?? 0
        return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
    }
    return zip(rgb(a), rgb(b)).map { abs($0 - $1) }.reduce(0, +) > 36
}
