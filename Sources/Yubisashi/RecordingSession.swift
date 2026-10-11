import AVFoundation
import AppKit

/// ホットキーを押してから、もう一度押すまでの1回分の記録
final class RecordingSession {
    let dir: URL
    let rawFramesDir: URL
    let startDate: Date
    private let screen: ScreenRecorder
    private var cursor: CursorTracker?
    private let audio = AudioRecorder()
    /// その場の書き起こし（字幕用）
    let caption = LiveCaption(languages: L.speechMode.fixed.map { [$0] } ?? Lang.allCases, preferred: L.likelySpeech)
    private var t0: Double = 0
    private let audioURL: URL
    private let videoURL: URL

    private init(dir: URL, displayID: CGDirectDisplayID) {
        self.dir = dir
        self.rawFramesDir = dir.appendingPathComponent("frames_raw", isDirectory: true)
        self.startDate = Date()
        self.audioURL = dir.appendingPathComponent("audio.wav")
        self.videoURL = dir.appendingPathComponent("recording.mp4")
        self.screen = ScreenRecorder(displayID: displayID, rawFramesDir: rawFramesDir)
    }

    /// 指定したディスプレイを記録し始める。メインスレッドから呼ぶ。
    /// いまカーソルがあるディスプレイ
    static func displayUnderCursor() -> CGDirectDisplayID {
        let location = CGEvent(source: nil)?.location ?? .zero
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(location, 8, &ids, &count)
        return count > 0 ? ids[0] : CGMainDisplayID()
    }

    static func start(outputRoot: URL, displayID: CGDirectDisplayID) async throws -> RecordingSession {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let dir = outputRoot.appendingPathComponent(fmt.string(from: Date()), isDirectory: true)

        let bounds = CGDisplayBounds(displayID)
        let backingScale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2

        let session = RecordingSession(dir: dir, displayID: displayID)
        // 記録（画面・声・書き起こし）は自分だけが読めるようにする
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true, attributes: ownerOnly)
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: outputRoot.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.createDirectory(at: session.rawFramesDir, withIntermediateDirectories: true)

        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard micGranted else {
            try? FileManager.default.removeItem(at: dir)
            throw YubisashiError(
                L.s(
                    "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク で Yubisashi を許可してください。",
                    "Microphone access is off. Allow Yubisashi in System Settings > Privacy & Security > Microphone."))
        }

        do {
            try await session.screen.start(
                videoURL: session.videoURL, captureMicrophone: true, backingScale: Double(backingScale))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        // 画面の記録が始まった瞬間を時刻の基準にする
        let t0 = CACurrentMediaTime()
        session.t0 = t0
        session.screen.t0 = t0
        let cursor = CursorTracker(displayBounds: bounds, t0: t0)
        cursor.start()
        session.cursor = cursor
        do {
            try session.audio.start(url: session.audioURL, t0: t0)
        } catch {
            cursor.stop()
            _ = await session.screen.stop()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        // 字幕の準備は記録の開始を待たせない
        Task { try? await session.caption.start() }
        return session
    }

    /// 帯を操作している間のカーソルを記録から外す
    func excludeCursor(in rect: @escaping () -> CGRect?) {
        cursor?.exclusion = rect
    }

    var elapsed: Double { CACurrentMediaTime() - t0 }

    /// 声の大きさ（0〜1）
    var audioLevel: Double { audio.level() }

    /// 記録を止めて生データを返す。メインスレッドから呼ぶ。
    func stop() async -> RecordingData {
        let duration = elapsed
        caption.stop()
        cursor?.stop()
        audio.stop()
        // 調べている途中の要素があれば、少しだけ待つ
        for _ in 0..<10 where (cursor?.pendingProbes ?? 0) > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let (frames, transitions, hasVideo) = await screen.stop()
        return RecordingData(
            dir: dir,
            rawFramesDir: rawFramesDir,
            startDate: startDate,
            duration: duration,
            displaySize: screen.displaySize,
            frameSize: screen.frameSize,
            frames: frames,
            transitions: transitions,
            cursor: cursor?.samples ?? [],
            clicks: cursor?.clicks ?? [],
            scrolls: cursor?.scrolls ?? [],
            audioURL: audioURL,
            audioOffset: audio.startOffset,
            videoURL: hasVideo ? videoURL : nil,
            speechLanguage: L.speech,
            detectSpeechLanguage: L.speechMode == .auto,
            probes: cursor?.probes ?? [])
    }

    /// 記録を止めて、保存したものをすべて消す
    func cancel() async {
        caption.stop()
        cursor?.stop()
        audio.stop()
        _ = await screen.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}
