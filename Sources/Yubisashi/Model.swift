import CoreGraphics
import Foundation

/// カーソル位置。座標は記録したディスプレイの左上を原点とするポイント値。
struct CursorSample: Codable {
    var t: Double
    var x: Double
    var y: Double
    /// 記録中のディスプレイ上にあるか
    var on: Bool
}

struct ClickEvent: Codable {
    var t: Double
    var x: Double
    var y: Double
    var button: String
}

/// 画面の変化を検知して保存したコマ
struct FrameRecord: Codable {
    var t: Double
    var file: String
    /// 直前に保存したコマとの差分の割合（0〜1）
    var change: Double
}

/// 書き起こしの1文字と、それを話した時刻（記録開始からの秒）
struct CharStamp: Codable {
    var ch: String
    var start: Double
    var end: Double
}

/// 記録セッションが終わった時点で揃っている生データ
struct RecordingData {
    var dir: URL
    var rawFramesDir: URL
    var startDate: Date
    var duration: Double
    /// 記録したディスプレイの大きさ（ポイント）
    var displaySize: CGSize
    /// 保存したコマの大きさ（ピクセル）
    var frameSize: CGSize
    var frames: [FrameRecord]
    var transitions: [Double]
    var cursor: [CursorSample]
    var clicks: [ClickEvent]
    var scrolls: [Double]
    var audioURL: URL
    /// 録音が始まった時刻（記録開始からの秒）
    var audioOffset: Double
    var videoURL: URL?
    var speechLanguage: Lang = L.speech
    /// 話す言語を自動で判定するか（そのときは書き起こしの後で speechLanguage が決まる）
    var detectSpeechLanguage = false
    /// 止まった所・クリックした所にある UI 要素（アクセシビリティの許可があるときだけ）
    var probes: [ElementProbeRecord] = []

    /// ポイント → コマ画像のピクセルへの倍率
    var pixelScale: Double { frameSize.width / max(displaySize.width, 1) }
}

struct YubisashiError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func formatTime(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

func circled(_ n: Int) -> String {
    switch n {
    case 1...20: return String(UnicodeScalar(0x2460 + n - 1)!)
    case 21...35: return String(UnicodeScalar(0x3251 + n - 21)!)
    case 36...50: return String(UnicodeScalar(0x32B1 + n - 36)!)
    default: return "(\(n))"
    }
}
