import AppKit
import Combine
import QuartzCore
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private let pink = CGColor(srgbRed: 1.0, green: 0.12, blue: 0.56, alpha: 1)  // #FF1F8F
private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

/// 記録中であることを画面に示す。
/// - 記録中のディスプレイの枠、カーソルの輪・軌跡の残像・止まったときのリング・クリックの波紋
/// - 画面下の帯（状態、経過時間、声の大きさ、終了・破棄のボタン）と、その上の字幕（その場の書き起こし）
/// 自分のアプリのウインドウは記録から除外しているので、動画にもコマにも写らない。
final class OverlayController {
    let screen: NSScreen
    /// 帯の「終了」「破棄」が押されたとき
    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let cursorWindow: NSWindow
    private let cursorView: CursorOverlayView
    private let hudPanel: NSPanel
    private let captionPanel: NSPanel
    private let hudHost: NSHostingView<HUDView>
    private let captionHost: NSHostingView<CaptionView>
    private let hud = HUDModel()
    private var clickMonitor: Any?
    private var frameCount = 0
    private var changes: AnyCancellable?

    init(screen: NSScreen) {
        self.screen = screen

        cursorWindow = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        cursorView = CursorOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        hudPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        captionPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hudHost = FirstMouseHostingView(rootView: HUDView(model: hud))
        captionHost = NSHostingView(rootView: CaptionView(model: hud))

        for w in [cursorWindow, hudPanel, captionPanel] {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.level = .screenSaver
        }
        cursorWindow.contentView = cursorView
        cursorWindow.setFrame(screen.frame, display: false)
        hudPanel.contentView = hudHost
        hudPanel.becomesKeyOnlyIfNeeded = true
        captionPanel.contentView = captionHost

        hud.onStop = { [weak self] in self?.onStop?() }
        hud.onDiscard = { [weak self] in self?.onDiscard?() }
        // 中身が変わったら、パネルを中身の大きさに合わせる（透明な所でクリックを邪魔しないため）
        changes = hud.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutPanels() }
        }
        layoutPanels()
    }

    /// 帯がある範囲（グローバル座標・左上原点）。ここでのカーソルの動きは記録に入れない
    var hudFrameInScreenCoordinates: CGRect? {
        guard hudPanel.isVisible, !hudPanel.ignoresMouseEvents else { return nil }
        let f = hudPanel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height).insetBy(dx: -8, dy: -8)
    }

    /// ホットキーを押した直後。記録の準備ができるまでの間も、押したことがすぐ分かるようにする
    func showStarting() {
        hud.phase = .starting
        hudPanel.alphaValue = 1
        hudPanel.orderFrontRegardless()
    }

    func startRecording(level: @escaping () -> Double, elapsed: @escaping () -> Double) {
        hud.phase = .recording
        hudPanel.ignoresMouseEvents = false
        cursorWindow.orderFrontRegardless()
        captionPanel.orderFrontRegardless()
        cursorView.onFrame = { [weak self] in
            guard let self else { return 0 }
            let l = level()
            self.frameCount += 1
            // 帯の更新は 1/3 の頻度で十分
            if self.frameCount % 3 == 0 {
                self.hud.level = l
                self.hud.elapsed = elapsed()
            }
            return l
        }
        cursorView.start()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.cursorView.ripple()
        }
    }

    /// その場の書き起こしを字幕に出す
    func updateCaption(_ state: LiveCaption.State) {
        hud.captionFinal = state.finalized
        hud.captionVolatile = state.volatile
        hud.captionLanguage = state.language
    }

    func showProcessing() {
        stopCursor()
        hud.phase = .processing
    }

    /// 結果を見せてから閉じる
    func finish(_ phase: HUDModel.Phase, after delay: Double) {
        stopCursor()
        hud.phase = phase
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                hudPanel.animator().alphaValue = 0
            }, completionHandler: { [self] in
                close()
            })
        }
    }

    func close() {
        stopCursor()
        cursorWindow.orderOut(nil)
        hudPanel.orderOut(nil)
        captionPanel.orderOut(nil)
    }

    private func stopCursor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        cursorView.stop()
        hudPanel.ignoresMouseEvents = true
        captionPanel.orderOut(nil)
    }

    private func layoutPanels() {
        let visible = screen.visibleFrame
        let hudSize = hudHost.fittingSize
        let hudFrame = NSRect(
            x: (visible.midX - hudSize.width / 2).rounded(), y: visible.minY + 16, width: hudSize.width,
            height: hudSize.height)
        if hudPanel.frame != hudFrame { hudPanel.setFrame(hudFrame, display: true) }

        let capSize = captionHost.fittingSize
        let capFrame = NSRect(
            x: (visible.midX - capSize.width / 2).rounded(), y: hudFrame.maxY + 8, width: capSize.width,
            height: capSize.height)
        if captionPanel.frame != capFrame { captionPanel.setFrame(capFrame, display: true) }
    }
}

/// 前面にないパネルでも、最初のクリックでボタンが押せるようにする
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - カーソルまわりの表示

final class CursorOverlayView: NSView {
    /// 毎フレーム呼ばれ、声の大きさ（0〜1）を返す
    var onFrame: () -> Double = { 0 }

    private let border = CAShapeLayer()
    private let trailLayers = (0..<6).map { _ in CAShapeLayer() }
    private let halo = CAShapeLayer()
    private let dwellRing = CAShapeLayer()
    private var trail: [(p: CGPoint, t: CFTimeInterval)] = []
    private var dwellAnchor: (p: CGPoint, t: CFTimeInterval)?
    private var dwellRegistered = false
    private var link: CADisplayLink?
    private var lastPoint: CGPoint = .zero

    private let trailLife = 0.9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = layer!

        border.fillColor = nil
        border.strokeColor = pink
        border.lineWidth = 3
        border.shadowColor = pink
        border.shadowRadius = 10
        border.shadowOpacity = 0.9
        border.shadowOffset = .zero
        border.opacity = 0
        root.addSublayer(border)

        for (i, l) in trailLayers.enumerated() {
            l.fillColor = nil
            l.strokeColor = pink.copy(alpha: 0.1 + 0.13 * CGFloat(i))
            l.lineWidth = 4
            l.lineCap = .butt
            l.lineJoin = .round
            root.addSublayer(l)
        }

        dwellRing.fillColor = nil
        dwellRing.strokeColor = pink
        dwellRing.lineWidth = 3
        dwellRing.lineCap = .round
        dwellRing.isHidden = true
        root.addSublayer(dwellRing)

        halo.fillColor = pink.copy(alpha: 0.10)
        halo.strokeColor = pink
        halo.lineWidth = 2
        halo.shadowColor = pink
        halo.shadowOffset = .zero
        halo.shadowRadius = 6
        halo.shadowOpacity = 0
        halo.isHidden = true
        root.addSublayer(halo)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    func start() {
        layout()
        // 枠: 太い線からすっと細くなって現れ、その後ゆっくり明滅する
        let width = CABasicAnimation(keyPath: "lineWidth")
        width.fromValue = 16
        width.toValue = 3
        width.duration = 0.4
        width.timingFunction = CAMediaTimingFunction(name: .easeOut)
        border.add(width, forKey: "intro")
        border.opacity = 1
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.beginTime = CACurrentMediaTime() + 0.4
        border.add(pulse, forKey: "pulse")

        link?.invalidate()
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// 開発用: 枠を表示した状態にする（アニメーションなし）
    func showBorderForSnapshot() {
        layout()
        border.opacity = 1
    }

    func stop() {
        link?.invalidate()
        link = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        border.removeAllAnimations()
        border.opacity = 0
        halo.isHidden = true
        dwellRing.isHidden = true
        trailLayers.forEach { $0.path = nil }
        CATransaction.commit()
        trail.removeAll()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        update(
            point: CGPoint(x: global.x - window.frame.minX, y: global.y - window.frame.minY),
            onScreen: NSMouseInRect(global, window.frame, false),
            now: CACurrentMediaTime(), level: onFrame())
    }

    /// 1フレーム分の表示を更新する。p はこのビューの座標（左下原点）
    func update(point p: CGPoint, onScreen: Bool, now: CFTimeInterval, level: Double) {
        lastPoint = p

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 軌跡の残像: 古いほど薄く
        if onScreen, trail.last.map({ hypot($0.p.x - p.x, $0.p.y - p.y) > 1 }) ?? true {
            trail.append((p, now))
        }
        if !onScreen { trail.removeAll() }
        trail.removeAll { now - $0.t > trailLife }
        let chunk = trailLife / Double(trailLayers.count)
        for (i, l) in trailLayers.enumerated() {
            // i が大きいほど新しい
            let newest = Double(trailLayers.count - 1 - i) * chunk
            let oldest = newest + chunk
            let pts = trail.enumerated().filter { k, e in
                let age = now - e.t
                let nextAge = k + 1 < trail.count ? now - trail[k + 1].t : 0
                return (age <= oldest && age >= newest) || (age > oldest && nextAge <= oldest)
            }.map(\.element.p)
            if pts.count >= 2 {
                let path = CGMutablePath()
                path.addLines(between: pts)
                l.path = path
            } else {
                l.path = nil
            }
        }

        // カーソルの輪: 声が大きいほど大きく明るくなる
        halo.isHidden = !onScreen
        let r = 15 + 9 * level
        halo.path = CGPath(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2), transform: nil)
        halo.lineWidth = 2 + 2 * level
        halo.shadowOpacity = Float(level)
        halo.fillColor = pink.copy(alpha: 0.08 + 0.17 * level)

        // 止まったときのリング: Analyzer と同じ条件（半径・時間）で満ちる
        if onScreen, let a = dwellAnchor, hypot(a.p.x - p.x, a.p.y - p.y) <= Analyzer.dwellRadius {
            let held = now - a.t
            let progress = max(0, min(1, (held - 0.08) / (Analyzer.dwellMinDuration - 0.08)))
            dwellRing.isHidden = progress <= 0 || dwellRegistered
            let path = CGMutablePath()
            path.addArc(
                center: a.p, radius: 27, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            dwellRing.path = path
            dwellRing.strokeEnd = progress
            if progress >= 1, !dwellRegistered {
                dwellRegistered = true
                pin(at: a.p)
            }
        } else {
            dwellAnchor = onScreen ? (p, now) : nil
            dwellRegistered = false
            dwellRing.isHidden = true
        }

        CATransaction.commit()
    }

    /// 「止まる」と判定された位置に点を残す
    private func pin(at p: CGPoint) {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12), transform: nil)
        dot.fillColor = pink
        dot.strokeColor = white
        dot.lineWidth = 2
        layer?.addSublayer(dot)

        let burst = CAShapeLayer()
        burst.path = CGPath(ellipseIn: CGRect(x: p.x - 27, y: p.y - 27, width: 54, height: 54), transform: nil)
        burst.fillColor = nil
        burst.strokeColor = pink
        burst.lineWidth = 3
        layer?.addSublayer(burst)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            dot.removeFromSuperlayer()
            burst.removeFromSuperlayer()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.9
        fade.duration = 0.5
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        dot.add(fade, forKey: "fade")
        let burstFade = CABasicAnimation(keyPath: "opacity")
        burstFade.fromValue = 0.9
        burstFade.toValue = 0
        burstFade.duration = 0.35
        burstFade.fillMode = .both
        burstFade.isRemovedOnCompletion = false
        burst.add(burstFade, forKey: "fade")
        CATransaction.commit()
    }

    /// クリックした位置に広がる波紋
    func ripple() {
        let p = lastPoint
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 68, height: 68), transform: nil)
        ring.fillColor = pink.copy(alpha: 0.15)
        ring.strokeColor = pink
        ring.lineWidth = 3
        layer?.addSublayer(ring)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.2
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }
}

// MARK: - 画面下の帯と字幕

final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        case recording
        case processing
        case done(String, String)
        case cancelled
    }

    @Published var phase: Phase = .starting
    @Published var elapsed: Double = 0
    @Published var level: Double = 0
    @Published var captionFinal = ""
    @Published var captionVolatile = ""
    @Published var captionLanguage: Lang?
    /// 「破棄」を1回押して、確認を待っている
    @Published var confirmingDiscard = false

    var onStop: (() -> Void)?
    var onDiscard: (() -> Void)?
}

private let pinkColor = Color(red: 1.0, green: 0.12, blue: 0.56)

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, model.phase == .recording ? 7 : 16)
        .padding(.vertical, model.phase == .recording ? 6 : 10)
        .frame(minHeight: 38)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(10)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.3), value: model.phase)
        .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .starting:
            Spinner()
            Text(L.s("開始しています…", "Starting…"))
        case .recording:
            RecDot()
            Text(L.s("記録中", "Recording"))
            Text(formatTime(model.elapsed)).monospacedDigit().foregroundStyle(.white.opacity(0.65))
            LevelBars(level: model.level)
            HUDButton(
                title: L.s("終了", "Stop"), systemImage: "stop.fill", hint: "⌃⌥R", tint: pinkColor
            ) { model.onStop?() }
            if model.confirmingDiscard {
                HUDButton(title: L.s("破棄する？", "Discard?"), systemImage: "trash", hint: nil, tint: .red) {
                    model.onDiscard?()
                }
            } else {
                HUDButton(title: nil, systemImage: "xmark", hint: nil, tint: nil) {
                    // うっかり押しても消えないよう、もう一度押したときだけ破棄する
                    model.confirmingDiscard = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.confirmingDiscard = false }
                }
                .help(L.s("記録を破棄", "Discard recording"))
            }
        case .processing:
            Spinner()
            Text(L.s("書き出しています…", "Exporting…"))
        case .done(let title, let detail):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(title)
            Text(detail).foregroundStyle(.white.opacity(0.6))
        case .cancelled:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
            Text(L.s("破棄しました", "Discarded"))
        }
    }
}

/// 帯の中の小さなボタン
private struct HUDButton: View {
    let title: String?
    let systemImage: String
    let hint: String?
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
                if let title { Text(title) }
                if let hint { Text(hint).foregroundStyle(.white.opacity(0.55)) }
            }
            .padding(.horizontal, title == nil ? 8 : 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill((tint ?? .white).opacity(hovering ? 0.38 : (tint == nil ? 0.12 : 0.26))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 帯の上の字幕。話している内容をその場で出す（確定した文字は白、聞き取り中は薄く）
struct CaptionView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        let (head, tail) = visibleText()
        Group {
            if model.phase == .recording, !(head + tail).isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "mic.fill").foregroundStyle(pinkColor)
                    (Text(head).foregroundColor(.white) + Text(tail).foregroundColor(.white.opacity(0.5)))
                        .lineLimit(2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let lang = model.captionLanguage {
                        Text(lang.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.72)))
                .padding(10)
            }
        }
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// 最後の部分だけを出す（長くなっても帯が伸びすぎないように）
    private func visibleText() -> (String, String) {
        let limit = model.captionLanguage == .en ? 110 : 56
        var head = model.captionFinal
        var tail = model.captionVolatile
        let overflow = head.count + tail.count - limit
        if overflow > 0 {
            if overflow >= head.count {
                tail = "…" + String(tail.dropFirst(overflow - head.count))
                head = ""
            } else {
                head = "…" + String(head.dropFirst(overflow))
            }
        }
        return (head, tail)
    }
}

private struct Spinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(pinkColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

private struct RecDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.23, blue: 0.19))
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// 声の大きさを示す5本のバー
private struct LevelBars: View {
    var level: Double
    private let weights: [Double] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(pinkColor.opacity(level > 0.02 ? 1 : 0.45))
                    .frame(width: 3, height: 4 + 14 * level * weights[i])
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.08), value: level)
    }
}
