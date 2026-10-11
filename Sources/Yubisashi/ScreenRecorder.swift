import AppKit
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// 画面を2本のストリームで記録する。
/// - 動画用: カーソルと声を含む mp4（人が見返す用）
/// - コマ用: カーソルなしの静止画。画面が変わったときだけ保存する（AI に渡す画像の素材）
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate {
    let displayID: CGDirectDisplayID
    let frameStore: FrameStore
    private(set) var frameSize: CGSize = .zero
    private(set) var displaySize: CGSize = .zero

    private var videoStream: SCStream?
    private var frameStream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished = false
    private let frameQueue = DispatchQueue(label: "yubisashi.frames")

    /// コマの時刻の基準（CACurrentMediaTime）。開始後に確定する。
    var t0: Double = 0

    init(displayID: CGDirectDisplayID, rawFramesDir: URL) {
        self.displayID = displayID
        self.frameStore = FrameStore(dir: rawFramesDir)
    }

    func start(videoURL: URL?, captureMicrophone: Bool, backingScale: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw YubisashiError(L.s("記録するディスプレイが見つかりませんでした。", "Could not find the display to record."))
        }
        // 自分のウインドウ（メニューバーのアイコンなど）は写さない
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let pw = Double(display.width)
        let ph = Double(display.height)
        displaySize = CGSize(width: pw, height: ph)

        // コマ用: 長辺 1600px まで。AI が読みやすく、画像として扱いやすい大きさ
        let fs = min(backingScale, 1600 / max(pw, ph))
        let fc = SCStreamConfiguration()
        fc.width = even(pw * fs)
        fc.height = even(ph * fs)
        fc.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        fc.showsCursor = false
        fc.pixelFormat = kCVPixelFormatType_32BGRA
        fc.colorSpaceName = CGColorSpace.sRGB
        fc.queueDepth = 3
        frameSize = CGSize(width: fc.width, height: fc.height)

        let fstream = SCStream(filter: filter, configuration: fc, delegate: self)
        try fstream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        frameStream = fstream

        if let videoURL {
            let vs = min(backingScale, 1920 / pw)
            let vc = SCStreamConfiguration()
            vc.width = even(pw * vs)
            vc.height = even(ph * vs)
            vc.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            vc.showsCursor = true
            vc.showMouseClicks = true
            vc.captureMicrophone = captureMicrophone
            vc.queueDepth = 6

            let vstream = SCStream(filter: filter, configuration: vc, delegate: self)
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = videoURL
            rc.outputFileType = .mp4
            rc.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: rc, delegate: self)
            try vstream.addRecordingOutput(output)
            recordingOutput = output
            videoStream = vstream
        }

        try await fstream.startCapture()
        if let videoStream {
            do {
                try await videoStream.startCapture()
            } catch {
                // 動画は人が見返す用なので、失敗しても記録自体は続ける
                NSLog("Yubisashi: video capture failed: \(error)")
                self.videoStream = nil
                self.recordingOutput = nil
            }
        }
    }

    /// 停止して、保存したコマの一覧と画面遷移の時刻を返す
    func stop() async -> (frames: [FrameRecord], transitions: [Double], hasVideo: Bool) {
        if let frameStream { try? await frameStream.stopCapture() }
        var hasVideo = false
        if let videoStream {
            try? await videoStream.stopCapture()
            // mp4 の書き出しが終わるのを最大5秒待つ
            for _ in 0..<50 where !recordingFinished {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            hasVideo = recordingFinished
        }
        let result = frameQueue.sync { (frameStore.records, frameStore.transitions) }
        return (result.0, result.1, hasVideo)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return }
        let t = max(0, CACurrentMediaTime() - t0)
        frameStore.add(image, t: t)
    }

    // MARK: SCStreamDelegate / SCRecordingOutputDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Yubisashi: stream stopped with error: \(error)")
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        recordingFinished = true
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("Yubisashi: recording failed: \(error)")
    }

    private func even(_ v: Double) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
}

/// コマ用ストリームの画像を受け取り、前回保存したコマから変化があったときだけ JPEG で保存する。
/// frameQueue 上からだけ触る。
final class FrameStore {
    let dir: URL
    private(set) var records: [FrameRecord] = []
    private(set) var transitions: [Double] = []
    private var lastThumb: [UInt8]?
    private var index = 0

    private let thumbW = 64
    private let thumbH = 40
    /// これより小さい変化は保存しない（カーソル以外の細かいちらつき）
    private let saveThreshold = 0.004
    /// これより大きい変化は「画面遷移」とみなす
    private let transitionThreshold = 0.25

    init(dir: URL) { self.dir = dir }

    func add(_ image: CGImage, t: Double) {
        let thumb = thumbnail(image)
        var change = 1.0
        if let lastThumb {
            change = diff(lastThumb, thumb)
            if change < saveThreshold { return }
        }
        index += 1
        let name = String(format: "f%05d.jpg", index)
        writeJPEG(image, to: dir.appendingPathComponent(name), quality: 0.92)
        records.append(FrameRecord(t: t, file: name, change: change))
        if lastThumb != nil, change > transitionThreshold {
            // ページの読み込みなどで1秒以内に続けて変わったものは1回にまとめる
            if let last = transitions.last, t - last < 1.0 {
            } else {
                transitions.append(t)
            }
        }
        lastThumb = thumb
    }

    private func thumbnail(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: thumbW * thumbH)
        bytes.withUnsafeMutableBytes { buf in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: thumbW, height: thumbH, bitsPerComponent: 8,
                    bytesPerRow: thumbW, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        }
        return bytes
    }

    private func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var changed = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > 20 {
            changed += 1
        }
        return Double(changed) / Double(a.count)
    }
}

func writeJPEG(_ image: CGImage, to url: URL, quality: Double) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
