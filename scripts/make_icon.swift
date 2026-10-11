// アプリアイコンを作る: swift scripts/make_icon.swift
// ピンクの軌跡（薄→濃）がカーソルに届き、指した位置に番号①が付く。Resources/AppIcon.icns を書き出す。
import AppKit
import CoreText

let size: CGFloat = 1024
let pink = CGColor(srgbRed: 1.0, green: 0.12, blue: 0.56, alpha: 1)
let lightPink = CGColor(srgbRed: 1.0, green: 0.72, blue: 0.86, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let ink = CGColor(srgbRed: 0.09, green: 0.08, blue: 0.17, alpha: 1)

func rgb(_ v: Int) -> CGColor {
    CGColor(
        srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    let ca = a.components!, cb = b.components!
    return CGColor(
        srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t, blue: ca[2] + (cb[2] - ca[2]) * t,
        alpha: 1)
}

func bezier(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}

func render() -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 左上原点で描く
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    // 本体（macOS のアイコンの枠に合わせて 824px の角丸）
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x241F45))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [rgb(0x43307A), rgb(0x16132E)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 120), end: CGPoint(x: 860, y: 920), options: [])
    // 指した所のまわりをほんのり明るく
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [pink.copy(alpha: 0.35)!, pink.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
        glow, startCenter: CGPoint(x: 600, y: 440), startRadius: 0, endCenter: CGPoint(x: 600, y: 440), endRadius: 360,
        options: [])

    // 軌跡: 左下から弧を描いて、指した所へ
    let p0 = CGPoint(x: 215, y: 800)
    let p1 = CGPoint(x: 235, y: 520)
    let p2 = CGPoint(x: 470, y: 720)
    let p3 = CGPoint(x: 590, y: 450)
    let steps = 80
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(48)
    var prev = p0
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = bezier(p0, p1, p2, p3, t)
        ctx.setStrokeColor(mix(lightPink, pink, t))
        ctx.move(to: prev)
        ctx.addLine(to: p)
        ctx.strokePath()
        prev = p
    }
    // 始点の○
    ctx.setFillColor(white)
    ctx.setStrokeColor(lightPink)
    ctx.setLineWidth(16)
    ctx.addEllipse(in: CGRect(x: p0.x - 34, y: p0.y - 34, width: 68, height: 68))
    ctx.drawPath(using: .fillStroke)

    // カーソル（先端が指した位置）
    let tip = p3
    let s: CGFloat = 12.5
    let arrow: [(CGFloat, CGFloat)] = [(0, 0), (0, 21), (5, 16.2), (8.6, 23.6), (11.6, 22.3), (8.1, 15.1), (15, 15.1)]
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: CGColor(gray: 0, alpha: 0.45))
    ctx.move(to: tip)
    for q in arrow.dropFirst() { ctx.addLine(to: CGPoint(x: tip.x + q.0 * s, y: tip.y + q.1 * s)) }
    ctx.closePath()
    ctx.setFillColor(white)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(14)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // 番号①: 指した位置の右上
    let badge = CGPoint(x: 760, y: 300)
    let r: CGFloat = 92
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(pink)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(18)
    ctx.addEllipse(in: CGRect(x: badge.x - r, y: badge.y - r, width: r * 2, height: r * 2))
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()
    // バッジと指した位置をつなぐ短い線
    ctx.setStrokeColor(white.copy(alpha: 0.9)!)
    ctx.setLineWidth(10)
    ctx.move(to: CGPoint(x: badge.x - r * 0.72, y: badge.y + r * 0.72))
    ctx.addLine(to: CGPoint(x: tip.x + 34, y: tip.y - 34))
    ctx.strokePath()

    let font = NSFont.systemFont(ofSize: 124, weight: .heavy) as CTFont
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "1", attributes: attrs))
    var ascent: CGFloat = 0, descent: CGFloat = 0
    let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: badge.x - w / 2 - 4, y: badge.y + (ascent - descent) / 2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()!
}

func png(_ image: CGImage, side: Int, to url: URL) {
    let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = render()
for base in [16, 32, 128, 256, 512] {
    png(master, side: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    png(master, side: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
png(master, side: 1024, to: root.appendingPathComponent("build/AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
