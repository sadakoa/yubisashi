import AVFoundation
import Speech

/// 端末内の音声認識（macOS 26 の SpeechAnalyzer）で、1文字ごとの時刻付きで書き起こす
enum Transcriber {
    struct Transcript {
        var stamps: [CharStamp]
        var language: Lang
        /// 書き起こしの確からしさ（文字数で重み付けした平均、0〜1）
        var confidence: Double
    }

    private static func makeModule(_ language: Lang) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: language.speechLocale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// 日本語と英語の両方で書き起こし、確からしい方を返す。
    /// 違う言語のモデルで聞くと確からしさが大きく下がる（実測で 0.9 前後と 0.1〜0.7）
    static func transcribeAuto(url: URL) async throws -> Transcript {
        async let ja = try? transcribeDetailed(url: url, language: .ja)
        async let en = try? transcribeDetailed(url: url, language: .en)
        let candidates = await [ja, en].compactMap { $0 }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            throw YubisashiError(L.s("書き起こしができませんでした。", "Could not transcribe the audio."))
        }
        return best
    }

    /// 話す言語のモデルが入っていなければダウンロードする
    static func prepare(_ language: Lang) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw YubisashiError(L.s("この Mac では端末内の音声認識を使えません。", "On-device speech recognition is not available on this Mac."))
        }
        let module = makeModule(language)
        _ = try? await AssetInventory.reserve(locale: language.speechLocale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    static func isReady(_ language: Lang) async -> Bool {
        await AssetInventory.status(forModules: [makeModule(language)]) == .installed
    }

    /// 音声ファイルを書き起こす。時刻は音声ファイルの先頭からの秒。
    static func transcribe(url: URL, language: Lang) async throws -> [CharStamp] {
        try await transcribeDetailed(url: url, language: language).stamps
    }

    static func transcribeDetailed(url: URL, language: Lang) async throws -> Transcript {
        try await prepare(language)
        let module = makeModule(language)
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () -> [SpeechTranscriber.Result] in
            var results: [SpeechTranscriber.Result] = []
            for try await r in module.results { results.append(r) }
            return results
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        var stamps: [CharStamp] = []
        var confidenceSum = 0.0
        var confidenceCount = 0
        for result in try await collector.value {
            for run in result.text.runs {
                let text = String(result.text[run.range].characters)
                if let c = run.transcriptionConfidence {
                    confidenceSum += c * Double(text.count)
                    confidenceCount += text.count
                }
                guard let range = run.audioTimeRange else { continue }
                var start = range.start.seconds
                let end = range.end.seconds
                // 1つの run に複数文字が入っている場合は時間を等分する
                let chars = Array(text)
                guard !chars.isEmpty, start.isFinite, end.isFinite else { continue }
                // 直前の無音が次の語の長さに含まれることがある（日本語は1文字、英語は1語ごと）。
                // 話すのに必要な長さより大幅に長ければ、前の部分は無音とみなす
                let letters = max(1, chars.filter { !$0.isWhitespace }.count)
                let natural = Double(letters) * (language == .ja ? 0.18 : 0.08) + 0.1
                if end - start > natural + 0.5 { start = end - natural }
                let step = (end - start) / Double(chars.count)
                for (i, c) in chars.enumerated() {
                    stamps.append(
                        CharStamp(ch: String(c), start: start + step * Double(i), end: start + step * Double(i + 1)))
                }
            }
        }
        return Transcript(
            stamps: stamps.sorted { $0.start < $1.start }, language: language,
            confidence: confidenceCount > 0 ? confidenceSum / Double(confidenceCount) : 0)
    }
}
