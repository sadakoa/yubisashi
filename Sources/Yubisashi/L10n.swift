import Foundation

enum Lang: String, Codable, CaseIterable {
    case ja, en

    var displayName: String { self == .ja ? "日本語" : "English" }
    var speechLocale: Locale { Locale(identifier: self == .ja ? "ja_JP" : "en_US") }
}

/// 話す言語の設定。自動のときは日本語と英語の両方で書き起こし、確からしい方を使う
enum SpeechMode: String, CaseIterable {
    case auto, ja, en

    var fixed: Lang? { Lang(rawValue: rawValue) }
    var label: String {
        switch self {
        case .auto: L.s("自動（日本語・英語）", "Auto (Japanese / English)")
        case .ja: Lang.ja.displayName
        case .en: Lang.en.displayName
        }
    }
}

/// 表示言語と話す言語。表示言語はメニュー・画面の表示・書き出す記録に使う。
enum L {
    /// 開発用（デモ動画など）に、設定を使わずに言語を固定する
    nonisolated(unsafe) static var override: Lang?
    nonisolated(unsafe) static var speechOverride: Lang?

    static var lang: Lang {
        get {
            if let override { return override }
            if let raw = UserDefaults.standard.string(forKey: "uiLanguage"), let l = Lang(rawValue: raw) { return l }
            return Locale.preferredLanguages.first?.hasPrefix("ja") == true ? .ja : .en
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "uiLanguage") }
    }

    /// 話す言語の設定。表示言語とは別に決める（表示は英語、話すのは日本語、という人もいるため）
    static var speechMode: SpeechMode {
        get {
            if let speechOverride { return SpeechMode(rawValue: speechOverride.rawValue)! }
            return UserDefaults.standard.string(forKey: "speechLanguage").flatMap(SpeechMode.init) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "speechLanguage") }
    }

    /// 決まった言語（自動のときは、書き起こすまで仮に表示言語）
    static var speech: Lang { speechMode.fixed ?? lang }

    /// その場の字幕で最初に見せる言語。前回の記録で判定した言語、なければシステムの言語に日本語があるか
    static var likelySpeech: Lang {
        if let fixed = speechMode.fixed { return fixed }
        if let raw = UserDefaults.standard.string(forKey: "lastSpeechLanguage"), let l = Lang(rawValue: raw) { return l }
        return Locale.preferredLanguages.contains { $0.hasPrefix("ja") } ? .ja : .en
    }

    static func rememberSpeech(_ language: Lang) {
        UserDefaults.standard.set(language.rawValue, forKey: "lastSpeechLanguage")
    }

    static func s(_ ja: String, _ en: String) -> String { lang == .ja ? ja : en }
}
