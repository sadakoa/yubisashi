import AVFoundation
import Speech

/// 記録中に、マイクの声をその場で書き起こす（画面下の字幕用）。
/// 記録に使う書き起こしは、終わった後に音声ファイルからやり直す。ここは「ちゃんと聞こえているか」を見せるためのもの。
final class LiveCaption {
    struct State {
        /// 確定した文字
        var finalized: String
        /// 聞き取り中でまだ変わりうる文字
        var volatile: String
        var language: Lang
    }

    /// 字幕が変わるたびにメインスレッドで呼ばれる
    var onUpdate: ((State) -> Void)?

    private final class Stream {
        let language: Lang
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        var converter: AVAudioConverter?
        var finalized = ""
        var volatile = ""
        var confidenceSum = 0.0
        var confidenceCount = 0
        var results: Task<Void, Never>?

        var meanConfidence: Double { confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : 0 }

        init(language: Lang, analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
            self.language = language
            self.analyzer = analyzer
            self.continuation = continuation
            self.format = format
        }
    }

    private let languages: [Lang]
    private let preferred: Lang
    private let engine = AVAudioEngine()
    private var streams: [Stream] = []
    private let lock = NSLock()
    private var stopped = false

    /// languages が2つなら両方で聞き、確定した文字の確からしさが高い方を見せる
    init(languages: [Lang], preferred: Lang) {
        self.languages = languages
        self.preferred = preferred
    }

    func start() async throws {
        try await startStreams()
        guard !streams.isEmpty, !stopped else { return }

        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 4096, format: node.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 開発用: マイクを使わずに始め、音を feedForTesting で流す
    func startForTesting() async throws { try await startStreams() }
    func feedForTesting(_ buffer: AVAudioPCMBuffer) { feed(buffer) }

    private func startStreams() async throws {
        for language in languages {
            let module = SpeechTranscriber(
                locale: language.speechLocale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence])
            // 記録中にモデルのダウンロードは始めない
            guard await AssetInventory.status(forModules: [module]) == .installed,
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
            else { continue }
            let analyzer = SpeechAnalyzer(modules: [module])
            let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: input)
            let stream = Stream(language: language, analyzer: analyzer, continuation: continuation, format: format)
            stream.results = Task { [weak self] in
                do {
                    for try await result in module.results { self?.handle(result, in: stream) }
                } catch {}
            }
            streams.append(stream)
        }
    }

    func stop() {
        stopped = true
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        for s in streams {
            s.continuation.finish()
            s.results?.cancel()
            let analyzer = s.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
        streams.removeAll()
    }

    /// マイクの音を、それぞれの書き起こしが受け取れる形式に直して渡す（音声処理のスレッドで呼ばれる）
    private func feed(_ buffer: AVAudioPCMBuffer) {
        for s in streams {
            if s.converter == nil { s.converter = AVAudioConverter(from: buffer.format, to: s.format) }
            guard let converter = s.converter else { continue }
            let ratio = s.format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let out = AVAudioPCMBuffer(pcmFormat: s.format, frameCapacity: capacity) else { continue }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { s.continuation.yield(AnalyzerInput(buffer: out)) }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result, in s: Stream) {
        let text = String(result.text.characters)
        lock.lock()
        if result.isFinal {
            s.finalized += text
            s.volatile = ""
            for run in result.text.runs {
                guard let c = run.transcriptionConfidence else { continue }
                let n = result.text[run.range].characters.count
                s.confidenceSum += c * Double(n)
                s.confidenceCount += n
            }
        } else {
            s.volatile = text
        }
        let state = current()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(state) }
    }

    /// 確定した文字がある程度たまったら確からしい方、それまでは前回の言語を見せる
    private func current() -> State {
        let decided = streams.filter { $0.confidenceCount >= 4 }.max { $0.meanConfidence < $1.meanConfidence }
        let shown = decided ?? streams.first { $0.language == preferred } ?? streams[0]
        return State(finalized: shown.finalized, volatile: shown.volatile, language: shown.language)
    }
}
