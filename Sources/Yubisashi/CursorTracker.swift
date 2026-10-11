import AVFoundation
import AppKit

/// カーソル位置を 60Hz で読み取り、クリックとスクロールも記録する。メインスレッドで動かす。
final class CursorTracker {
    let displayBounds: CGRect
    let t0: Double
    private(set) var samples: [CursorSample] = []
    private(set) var clicks: [ClickEvent] = []
    private(set) var scrolls: [Double] = []
    /// 止まった所・クリックした所にある UI 要素
    private(set) var probes: [ElementProbeRecord] = []
    private(set) var pendingProbes = 0

    /// ここにカーソルがある間は記録しない（画面下の帯を操作しているとき）。グローバル座標・左上原点
    var exclusion: (() -> CGRect?)?

    private let probe = ElementProbe()
    private var rest: (x: Double, y: Double, t: Double)?
    private var probedThisRest = false
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastStored: CursorSample?

    /// displayBounds はグローバル座標（左上原点、ポイント）
    init(displayBounds: CGRect, t0: Double) {
        self.displayBounds = displayBounds
        self.t0 = t0
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()

        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in self?.click(e) })
        {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.scrollWheel], handler: { [weak self] _ in self?.scroll() })
        {
            monitors.append(m)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        tick(force: true)
    }

    private var now: Double { CACurrentMediaTime() - t0 }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func tick(force: Bool = false) {
        let p = currentLocation()
        let excluded = exclusion?()?.contains(p) ?? false
        let s = CursorSample(
            t: now, x: p.x - displayBounds.minX, y: p.y - displayBounds.minY,
            on: displayBounds.contains(p) && !excluded)
        // 動いたとき、または 0.1 秒ごとに保存する（止まっている時間を正しく測るため）
        if let last = lastStored, !force {
            let moved = hypot(s.x - last.x, s.y - last.y) > 0.5 || s.on != last.on
            if !moved && s.t - last.t < 0.1 { return }
        }
        samples.append(s)
        lastStored = s

        // 0.2 秒止まったら、その位置の要素を調べる（止まる判定と同じ半径）
        guard s.on else {
            rest = nil
            return
        }
        if let r = rest, hypot(s.x - r.x, s.y - r.y) <= Analyzer.dwellRadius {
            if !probedThisRest, s.t - r.t >= 0.2 {
                probedThisRest = true
                inspect(x: r.x, y: r.y, t: r.t)
            }
        } else {
            rest = (s.x, s.y, s.t)
            probedThisRest = false
        }
    }

    private func inspect(x: Double, y: Double, t: Double) {
        guard ElementProbe.isTrusted else { return }
        pendingProbes += 1
        let global = CGPoint(x: x + displayBounds.minX, y: y + displayBounds.minY)
        probe.probe(globalPoint: global, displayOrigin: displayBounds.origin) { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingProbes -= 1
                if let info { self.probes.append(ElementProbeRecord(t: t, x: x, y: y, info: info)) }
            }
        }
    }

    private func click(_ e: NSEvent) {
        let p = e.cgEvent?.location ?? currentLocation()
        guard displayBounds.contains(p) else { return }
        let click = ClickEvent(
            t: now, x: p.x - displayBounds.minX, y: p.y - displayBounds.minY,
            button: e.type == .rightMouseDown ? "right" : "left")
        clicks.append(click)
        inspect(x: click.x, y: click.y, t: click.t)
    }

    private func scroll() {
        let t = now
        if let last = scrolls.last, t - last < 0.2 { return }
        scrolls.append(t)
    }
}

/// 声を 16kHz モノラルの WAV で録音する
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var startOffset: Double = 0

    func start(url: URL, t0: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        r.prepareToRecord()
        guard r.record() else {
            throw YubisashiError(
                L.s("録音を開始できませんでした。マイクの権限を確認してください。", "Could not start recording audio. Check microphone permission."))
        }
        startOffset = CACurrentMediaTime() - t0
        recorder = r
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }

    /// いまの声の大きさを 0〜1 で返す（-50dB 以下を 0、-10dB 以上を 1）
    func level() -> Double {
        guard let recorder else { return 0 }
        recorder.updateMeters()
        let db = Double(recorder.averagePower(forChannel: 0))
        return max(0, min(1, (db + 50) / 40))
    }
}
