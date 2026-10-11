import AppKit
import ApplicationServices

/// 指した位置にある UI 要素の情報（アクセシビリティ API から取る）
struct ElementInfo: Codable {
    var app: String?
    /// AXButton など
    var role: String?
    /// 表示名（タイトル・説明・値のうち最初にあるもの）
    var label: String?
    /// 中の文字（ボタンの中のテキストなど、label と違う場合）
    var text: String?
    var domId: String?
    var domClasses: [String]?
    /// Web ページの URL
    var url: String?
    /// 要素の位置と大きさ（記録したディスプレイの左上原点、ポイント）
    var frame: [Double]?
    /// 親要素のうち名前のあるもの（外側から順）
    var ancestors: [String]?
}

/// 記録中に、止まった所・クリックした所の要素を調べたもの
struct ElementProbeRecord: Codable {
    var t: Double
    var x: Double
    var y: Double
    var info: ElementInfo
}

/// アクセシビリティ API で、画面上の位置にある要素を調べる。
/// Web ページ（Safari / Chrome など）では DOM の id・class・URL も取れる。
/// 「アクセシビリティ」の許可がなければ何もしない。
final class ElementProbe {
    private let system = AXUIElementCreateSystemWide()
    private let queue = DispatchQueue(label: "yubisashi.ax")
    private var enabledPids = Set<pid_t>()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// システムの許可ダイアログを出す
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    init() {
        AXUIElementSetMessagingTimeout(system, 0.2)
    }

    /// globalPoint はグローバル座標（左上原点）。結果は記録したディスプレイの座標に直して返す
    func probe(globalPoint p: CGPoint, displayOrigin: CGPoint, completion: @escaping (ElementInfo?) -> Void) {
        guard Self.isTrusted else { return completion(nil) }
        queue.async { [self] in
            completion(inspect(p, origin: displayOrigin))
        }
    }

    private func inspect(_ p: CGPoint, origin: CGPoint) -> ElementInfo? {
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hitRef) == .success, let hit = hitRef
        else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        enableWebAccessibility(pid)

        // 文字や画像を指していたら、押せる親要素（ボタン・リンクなど）を対象にする
        let actionable: Set<String> = [
            "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuButton",
            "AXTextField", "AXTextArea", "AXComboBox", "AXTab", "AXSlider", "AXSwitch", "AXDisclosureTriangle",
        ]
        var target = hit
        var cursor: AXUIElement? = hit
        for _ in 0..<3 {
            guard let e = cursor else { break }
            if let role = string(e, kAXRoleAttribute), actionable.contains(role) {
                target = e
                break
            }
            cursor = parent(e)
        }

        // パスワード欄は何も記録しない
        if Self.isSecure(target) || Self.isSecure(hit) { return nil }

        var info = ElementInfo()
        info.app = NSRunningApplication(processIdentifier: pid)?.localizedName
        info.role = string(target, kAXRoleAttribute)
        info.label = label(target)
        if let hitLabel = label(hit), hitLabel != info.label { info.text = hitLabel }
        info.domId = string(target, "AXDOMIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        info.domClasses = (attr(target, "AXDOMClassList") as? [String]).flatMap { $0.isEmpty ? nil : Array($0.prefix(4)) }
        if let f = frame(target) {
            // 画面のほとんどを覆う要素（Web ページ全体など）は位置の手がかりにならない
            if f.width * f.height < 900 * 900 {
                let values: [Double] = [f.minX - origin.x, f.minY - origin.y, f.width, f.height].map { Double($0) }
                info.frame = values.map { ($0 * 10).rounded() / 10 }
            }
        }

        // 親をたどって、名前のある要素と Web ページの URL を集める
        var names: [String] = []
        var e = parent(target)
        var depth = 0
        while let el = e, depth < 12 {
            let role = string(el, kAXRoleAttribute)
            if role == "AXWebArea", info.url == nil, let url = attr(el, "AXURL") {
                info.url = Self.withoutQuery((url as? URL)?.absoluteString ?? (url as? String))
            }
            if role == "AXWindow" || role == "AXApplication" { break }
            if names.count < 3, let l = label(el), let role {
                names.insert("\(role.replacingOccurrences(of: "AX", with: ""))「\(l)」", at: 0)
            }
            e = parent(el)
            depth += 1
        }
        if !names.isEmpty { info.ancestors = names }
        return info
    }

    /// Chrome や Electron のアプリは、頼まないと Web の中身をアクセシビリティに出さない
    private func enableWebAccessibility(_ pid: pid_t) {
        guard pid > 0, !enabledPids.contains(pid) else { return }
        enabledPids.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private func string(_ e: AXUIElement, _ name: String) -> String? {
        attr(e, name) as? String
    }

    private func parent(_ e: AXUIElement) -> AXUIElement? {
        guard let v = attr(e, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// 入力欄の値（打ち込んだ文字）は読まない。名前・説明・プレースホルダーだけを使う
    private static let inputRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField",
    ]

    private static func isSecure(_ e: AXUIElement) -> Bool {
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &subrole)
        return (role as? String) == "AXSecureTextField" || (subrole as? String) == "AXSecureTextField"
    }

    /// URL の ? 以降と # 以降（トークンなどが入りうる）を落とす
    private static func withoutQuery(_ url: String?) -> String? {
        guard let url, var c = URLComponents(string: url) else { return url }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.string
    }

    private func label(_ e: AXUIElement) -> String? {
        let isInput = string(e, kAXRoleAttribute).map { Self.inputRoles.contains($0) } ?? false
        let names = isInput
            ? [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
            : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXPlaceholderValue"]
        for name in names {
            if let s = string(e, name)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s.count > 60 ? String(s.prefix(60)) + "…" : s
            }
        }
        return nil
    }

    private func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute),
            CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
