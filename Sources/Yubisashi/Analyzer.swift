import Foundation

// MARK: - 解析結果の型

struct Dwell {
    var start: Double
    var end: Double
    var x: Double
    var y: Double
    var duration: Double { end - start }
}

enum AnchorKind: String, Codable {
    case dwell, click, circle, area, pass
}

/// 番号を振って示す位置（①②…）
struct Anchor: Codable {
    var number = 0
    var t: Double
    var tEnd: Double
    var x: Double
    var y: Double
    var kind: AnchorKind
    var dwellDuration: Double = 0
    var clickButton: String?
    /// 囲んだ・示した範囲の半径（ポイント）
    var radius: Double = 0
    /// この位置を指した指示語（「これ」「ここ」など）
    var words: [String] = []
    var partIndex = 0
    var color: String?
    /// クローズアップ画像のファイル名
    var closeUp: String?
    /// 指した位置にある UI 要素（アクセシビリティの許可があるときだけ）
    var element: ElementInfo?
    /// 重複を防ぐためのキー（同じ停止やクリックを2回数えない）
    var key: String = ""
}

enum MoveKind: String, Codable {
    case still, fast, move, trace, loop, backForth

    var label: String {
        switch self {
        case .still: L.s("ほぼ動かない", "barely moved")
        case .fast: L.s("素早い移動", "fast move")
        case .move: L.s("移動", "moved")
        case .trace: L.s("ゆっくりなぞる", "traced slowly")
        case .loop: L.s("囲む", "circled")
        case .backForth: L.s("往復", "back and forth")
        }
    }
}

/// 画面の大きな変化
enum EventKind: String, Codable {
    case transition, scroll

    var label: String {
        switch self {
        case .transition: L.s("画面遷移", "screen change")
        case .scroll: L.s("スクロール", "scroll")
        }
    }
}

struct Move: Codable {
    var from: Int
    var to: Int
    var kind: MoveKind
    var length: Double
    var duration: Double
    var crosses: EventKind?
}

/// 区間の中の1枚の画像に対応する時間帯。画面遷移やスクロールで分かれる。
struct Part: Codable {
    var start: Double
    var end: Double
    var endsWith: EventKind?
    var frameFile: String?
    var imageName = ""
}

struct ScreenEvent: Codable {
    var t: Double
    var kind: EventKind
}

struct Segment: Codable {
    var index: Int
    var start: Double
    var end: Double
    var speech: Bool
    var plainText: String
    var markedText: String
    var parts: [Part]
    var anchors: [Anchor]
    var moves: [Move]
    var events: [ScreenEvent]
    var scrolled: Bool
}

// MARK: - 解析

/// 書き起こしとカーソルの動きを突き合わせて、区間・番号付きの位置・動きにまとめる
struct Analyzer {
    let data: RecordingData
    /// 記録開始からの秒に揃えた書き起こし
    let chars: [CharStamp]

    private struct TChar {
        var c: Character
        var start: Double
        var end: Double
    }

    // 指示語。長いものから順に照合する
    private static let deicticsJA = [
        "あそこ", "こっち", "そっち", "あっち", "こちら", "そちら", "あちら", "こんな", "そんな", "あんな",
        "ここ", "そこ", "これ", "それ", "あれ", "この", "その", "あの", "こう",
    ]
    private static let deicticsEN = ["these", "those", "this", "that", "here", "there"]
    // 指示語に見えて、指差しではないもの
    private static let exclusionsJA = [
        "それから", "それで", "それと", "それに", "それでも", "そのまま", "このまま", "あのー", "そのー", "あの、", "その、",
        "こうして", "そこで",
    ]
    // 「このあたり」「around here」のように、点ではなく範囲を指す言い方
    private static let areaWordsJA = ["あたり", "辺り", "らへん", "へん", "辺", "周り", "まわり", "部分", "エリア"]
    private static let areaWordsEN = ["area", "region", "part", "section", "around"]

    private var isEnglish: Bool { data.speechLanguage == .en }

    func run() -> [Segment] {
        let dwells = detectDwells()
        let events = screenEvents()
        // 無音の時間が次の文字の長さに含まれることがあるので、長すぎる文字は終わりの 0.3 秒だけを発音とみなす
        let tchars = chars.flatMap { s in
            Array(s.ch).map { TChar(c: $0, start: s.end - s.start > 0.7 ? s.end - 0.3 : s.start, end: s.end) }
        }
        let groups = utterances(tchars)

        // 発話のある区間
        var windows: [(start: Double, end: Double, chars: [TChar])] = []
        for (i, g) in groups.enumerated() {
            let s = g.first!.start
            let e = g.last!.end
            let prevEnd = i > 0 ? groups[i - 1].last!.end : 0
            let nextStart = i + 1 < groups.count ? groups[i + 1].first!.start : data.duration
            let lead = min(1.5, max(0, (s - prevEnd) / 2))
            let tail = min(1.0, max(0, (nextStart - e) / 2))
            windows.append((max(0, s - lead), min(data.duration, e + tail), g))
        }

        // 発話のない時間帯でも、クリック・画面遷移・長い停止があれば区間にする
        var silent: [(Double, Double)] = []
        var cursorT = 0.0
        for w in windows + [(data.duration, data.duration, [])] {
            if w.start - cursorT > 2.0, hasActivity(cursorT, w.start, dwells: dwells, events: events) {
                silent.append(contentsOf: chunk(cursorT, w.start, events: events))
            }
            cursorT = max(cursorT, w.end)
        }

        var raw: [(start: Double, end: Double, chars: [TChar])] =
            windows + silent.map { ($0.0, $0.1, [TChar]()) }
        raw.sort { $0.start < $1.start }
        if raw.isEmpty {
            raw = [(0, data.duration, [])]
        }

        return raw.enumerated().map { i, w in
            buildSegment(index: i + 1, start: w.start, end: w.end, chars: w.chars, dwells: dwells, events: events)
        }
    }

    // MARK: 発話のまとまり

    private func utterances(_ tchars: [TChar]) -> [[TChar]] {
        var groups: [[TChar]] = []
        var cur: [TChar] = []
        for tc in tchars {
            if let last = cur.last {
                let gap = tc.start - last.end
                let duration = last.end - cur[0].start
                let sentenceEnd = "。？！?!.".contains(last.c)
                // 1 秒以上の間か、文の終わりのあとの 0.8 秒以上の間で区切る
                if gap > 1.0 || (sentenceEnd && (gap > 0.8 || duration > 8)) {
                    groups.append(cur)
                    cur = []
                }
            }
            cur.append(tc)
        }
        if !cur.isEmpty { groups.append(cur) }
        // 句読点だけのまとまりは捨てる
        return groups.filter { g in g.contains { !"。、？！?!,. ".contains($0.c) } }
    }

    private func hasActivity(_ a: Double, _ b: Double, dwells: [Dwell], events: [ScreenEvent]) -> Bool {
        data.clicks.contains { $0.t >= a && $0.t < b }
            || events.contains { $0.t >= a && $0.t < b && $0.kind == .transition }
            || dwells.contains { $0.start >= a && $0.end <= b && $0.duration >= 1.5 }
    }

    /// 発話のない長い時間帯は、画面遷移と20秒ごとで区切る
    private func chunk(_ a: Double, _ b: Double, events: [ScreenEvent]) -> [(Double, Double)] {
        var cuts = [a] + events.filter { $0.t > a + 1 && $0.t < b - 1 && $0.kind == .transition }.map(\.t) + [b]
        var result: [(Double, Double)] = []
        cuts = cuts.sorted()
        for i in 0..<(cuts.count - 1) {
            var s = cuts[i]
            let e = cuts[i + 1]
            while e - s > 20 {
                result.append((s, s + 20))
                s += 20
            }
            if e - s > 0.5 { result.append((s, e)) }
        }
        return result
    }

    // MARK: 区間の組み立て

    private func buildSegment(
        index: Int, start: Double, end: Double, chars: [TChar], dwells: [Dwell], events: [ScreenEvent]
    ) -> Segment {
        let segEvents = events.filter { $0.t >= start && $0.t <= end }
        let parts = splitParts(start: start, end: end, events: segEvents)

        var anchors: [Anchor] = []
        var wordAnchorKeys: [(range: Range<Int>, key: String)] = []

        // 1. 指示語ごとに、その瞬間に指していた位置を探す
        var i = 0
        let cs = chars.map(\.c)
        // 英語は大文字小文字を区別せず、単語の途中では照合しない
        let lower = cs.map { Character($0.lowercased()) }
        let deictics = isEnglish ? Self.deicticsEN : Self.deicticsJA
        let exclusions = isEnglish ? [] : Self.exclusionsJA
        while i < cs.count {
            if exclusions.contains(where: { matches($0, in: lower, at: i) }) {
                i += 1
                continue
            }
            guard let word = deictics.first(where: { matches($0, in: lower, at: i) }) else {
                i += 1
                continue
            }
            let range = i..<(i + word.count)
            let t = chars[range.lowerBound].start
            let tEnd = chars[range.upperBound - 1].end
            let area = isAreaPhrase(lower, range)
            if var anchor = findAnchor(t: t, tEnd: tEnd, area: area, dwells: dwells) {
                let shown = String(cs[range])
                if let existing = anchors.firstIndex(where: { $0.key == anchor.key || sameRegion($0, anchor) }) {
                    anchors[existing].words.append(shown)
                    anchor.key = anchors[existing].key
                } else {
                    anchor.words = [shown]
                    anchors.append(anchor)
                }
                wordAnchorKeys.append((range, anchor.key))
            }
            i = range.upperBound
        }

        // 2. 指示語と結びつかなかった長い停止
        for (di, d) in dwells.enumerated() {
            let mid = (d.start + d.end) / 2
            guard mid >= start, mid < end, d.duration >= 1.2 else { continue }
            let key = "d\(di)"
            if anchors.contains(where: { $0.key == key }) { continue }
            // 直前に指した所（囲んだ範囲を含む）にそのまま置いているだけなら数えない
            if anchors.contains(where: {
                hypot($0.x - d.x, $0.y - d.y) < max(30, $0.radius) && abs($0.tEnd - d.start) < 3
            }) { continue }
            anchors.append(
                Anchor(
                    t: d.start, tEnd: d.end, x: d.x, y: d.y, kind: .dwell, dwellDuration: d.duration, key: key))
        }

        // 3. クリック。止まっている最中のクリックは、その停止に含める
        for (ci, c) in data.clicks.enumerated() where c.t >= start && c.t < end {
            let key = "c\(ci)"
            if anchors.contains(where: { $0.key == key }) { continue }
            if let j = anchors.firstIndex(where: {
                $0.kind == .dwell && c.t >= $0.t - 0.2 && c.t <= $0.tEnd + 0.2 && hypot($0.x - c.x, $0.y - c.y) < 15
            }) {
                anchors[j].clickButton = c.button
                continue
            }
            anchors.append(Anchor(t: c.t, tEnd: c.t, x: c.x, y: c.y, kind: .click, clickButton: c.button, key: key))
        }

        // 時刻順に番号を振り、その位置で調べた UI 要素を結びつける
        anchors.sort { $0.t < $1.t }
        for k in anchors.indices {
            anchors[k].number = k + 1
            anchors[k].partIndex = parts.lastIndex(where: { anchors[k].t >= $0.start }) ?? 0
            anchors[k].element = element(for: anchors[k])
        }

        // 発話に番号を差し込む（「この①ボタン」）
        var marked = ""
        for (ci, c) in cs.enumerated() {
            marked.append(c)
            for w in wordAnchorKeys where w.range.upperBound - 1 == ci {
                if let a = anchors.first(where: { $0.key == w.key }) { marked += circled(a.number) }
            }
        }

        // 番号と番号のあいだの動き
        var moves: [Move] = []
        if anchors.count >= 2 {
            for k in 1..<anchors.count {
                let a = anchors[k - 1]
                let b = anchors[k]
                let path = samples(from: a.tEnd, to: b.t)
                let (kind, length, duration) = classify(path)
                let crosses = segEvents.first { $0.t > a.t && $0.t <= b.t }?.kind
                if kind == .still && crosses == nil { continue }
                moves.append(Move(from: a.number, to: b.number, kind: kind, length: length, duration: duration, crosses: crosses))
            }
        } else if anchors.isEmpty {
            // 番号がないときだけ、区間全体の動きを書く（番号が1つなら、その前後は次の対象への移動であることが多い）
            let (kind, length, duration) = classify(samples(from: start, to: end))
            if kind != .still {
                moves.append(Move(from: 0, to: 0, kind: kind, length: length, duration: duration, crosses: nil))
            }
        }

        let plain = trimLeadingPunctuation(String(cs))
        return Segment(
            index: index, start: start, end: end, speech: !chars.isEmpty, plainText: plain,
            markedText: trimLeadingPunctuation(marked), parts: parts, anchors: anchors, moves: moves, events: segEvents,
            scrolled: data.scrolls.contains { $0 >= start && $0 <= end })
    }

    /// 書き起こしの先頭に残る「、」や空白を落とす（文末の「。」は残す）
    private func trimLeadingPunctuation(_ text: String) -> String {
        let leading = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",、。."))
        let start = text.unicodeScalars.firstIndex { !leading.contains($0) } ?? text.unicodeScalars.endIndex
        return String(text.unicodeScalars[start...]).trimmingCharacters(in: .whitespaces)
    }

    /// 番号の位置・時刻に近い所で調べた UI 要素
    private func element(for a: Anchor) -> ElementInfo? {
        let point = a.kind == .dwell || a.kind == .click
        let slack = point ? 0.3 : 1.5
        let reach = point ? 15 : max(30, a.radius)
        return data.probes
            .filter { $0.t >= a.t - slack && $0.t <= a.tEnd + slack && hypot($0.x - a.x, $0.y - a.y) < reach }
            .min { hypot($0.x - a.x, $0.y - a.y) < hypot($1.x - a.x, $1.y - a.y) }?
            .info
    }

    private func matches(_ word: String, in cs: [Character], at i: Int) -> Bool {
        let w = Array(word)
        guard i + w.count <= cs.count, Array(cs[i..<(i + w.count)]) == w else { return false }
        if isEnglish {
            if i > 0, cs[i - 1].isLetter { return false }
            if i + w.count < cs.count, cs[i + w.count].isLetter { return false }
        }
        return true
    }

    /// 指示語の前後が「あたり」「area」「around」など、範囲を指す言い方か
    private func isAreaPhrase(_ cs: [Character], _ range: Range<Int>) -> Bool {
        if isEnglish {
            let after = String(cs[range.upperBound...].prefix(12)).trimmingCharacters(in: .whitespaces)
            let before = String(cs[..<range.lowerBound].suffix(8)).trimmingCharacters(in: .whitespaces)
            return Self.areaWordsEN.contains { after.hasPrefix($0) } || before.hasSuffix("around")
        }
        // 「このあたり」「この辺」「ここらへん」（間に「の」が入る場合も含む）
        var j = range.upperBound
        if j < cs.count, cs[j] == "の" { j += 1 }
        let after = String(cs[j...].prefix(4))
        return Self.areaWordsJA.contains { after.hasPrefix($0) }
    }

    /// 範囲・囲み・通過の位置どうしで、同じ所を指しているか（「このあたりが、こう」）
    private func sameRegion(_ a: Anchor, _ b: Anchor) -> Bool {
        let soft: Set<AnchorKind> = [.area, .circle, .pass]
        guard soft.contains(b.kind), soft.contains(a.kind) else { return false }
        return hypot(a.x - b.x, a.y - b.y) < max(a.radius, b.radius, 30) + 20 && abs(b.t - a.tEnd) < 3
    }

    /// 区間を、画面遷移・スクロールの時刻で画像ごとの時間帯に分ける（最大4枚）
    private func splitParts(start: Double, end: Double, events: [ScreenEvent]) -> [Part] {
        let cuts = events.filter { $0.t > start + 0.3 && $0.t < end - 0.3 }
        var parts: [Part] = []
        var s = start
        for c in cuts {
            parts.append(Part(start: s, end: c.t, endsWith: c.kind))
            s = c.t
        }
        parts.append(Part(start: s, end: end, endsWith: nil))

        // 短すぎるもの・多すぎるものは隣とまとめる
        func mergeShortest() {
            guard parts.count > 1,
                let k = parts.indices.min(by: { parts[$0].end - parts[$0].start < parts[$1].end - parts[$1].start })
            else { return }
            if k + 1 < parts.count {
                parts[k + 1].start = parts[k].start
                parts.remove(at: k)
            } else {
                parts[k - 1].end = parts[k].end
                parts[k - 1].endsWith = parts[k].endsWith
                parts.remove(at: k)
            }
        }
        while parts.count > 1, parts.contains(where: { $0.end - $0.start < 0.6 }) { mergeShortest() }
        while parts.count > 4 { mergeShortest() }

        for k in parts.indices {
            parts[k].frameFile = frame(atOrBefore: parts[k].end - 0.05)?.file
        }
        return parts
    }

    // MARK: 指示語と位置の対応

    private func findAnchor(t: Double, tEnd: Double, area: Bool, dwells: [Dwell]) -> Anchor? {
        let lo = t - 0.7
        let hi = tEnd + 0.9
        func distance(_ a: Double, _ b: Double) -> Double { t < a ? a - t : (t > b ? t - b : 0) }

        let dwell = dwells.enumerated()
            .filter { $0.element.end > lo && $0.element.start < hi }
            .min { l, r in
                let dl = distance(l.element.start, l.element.end)
                let dr = distance(r.element.start, r.element.end)
                return dl == dr ? l.element.duration > r.element.duration : dl < dr
            }
        let click = data.clicks.enumerated()
            .filter { $0.element.t >= lo && $0.element.t <= hi }
            .min { abs($0.element.t - t) < abs($1.element.t - t) }

        // 言った瞬間に止まっておらず、その前後で囲んでいたら、囲んだ範囲を優先する
        let around = samples(from: t - 0.8, to: tEnd + 1.2)
        let dwellDuringWord = dwell.map { $0.element.start <= tEnd + 0.2 && $0.element.end >= t - 0.2 } ?? false
        if !dwellDuringWord, click == nil {
            let kind = classify(around).kind
            if kind == .loop { return regionAnchor(around, t: t, tEnd: tEnd, kind: .circle) }
            // 「このあたり」と言いながら動かしている、または小さな範囲を行き来している
            let wide = samples(from: t - 1.0, to: tEnd + 1.5)
            if area || kind == .backForth, let a = regionAnchor(wide, t: t, tEnd: tEnd, kind: .area, maxRadius: 260) {
                return a
            }
        }

        if let dwell, click == nil
            || distance(dwell.element.start, dwell.element.end) <= abs(click!.element.t - t)
        {
            let d = dwell.element
            return Anchor(
                t: d.start, tEnd: d.end, x: d.x, y: d.y, kind: .dwell, dwellDuration: d.duration, key: "d\(dwell.offset)")
        }
        if let click {
            let c = click.element
            return Anchor(t: c.t, tEnd: c.t, x: c.x, y: c.y, kind: .click, clickButton: c.button, key: "c\(click.offset)")
        }

        // 止まっていないとき: ゆっくり動いていればその瞬間の位置
        let near = samples(from: t - 0.15, to: t + 0.15)
        if let p = position(at: t), near.count >= 2 {
            let len = zip(near, near.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
            let speed = len / max(near.last!.t - near.first!.t, 0.01)
            if speed < 350 {
                return Anchor(t: t, tEnd: tEnd, x: p.x, y: p.y, kind: .pass, key: "p\(t)")
            }
        }
        return nil
    }

    /// 囲む・範囲を示す動きの中心と半径。端の行き来を除くため、最も外側ではなく 85% 点を半径にする
    private func regionAnchor(
        _ path: [CursorSample], t: Double, tEnd: Double, kind: AnchorKind, maxRadius: Double = .infinity
    ) -> Anchor? {
        guard path.count >= 3 else { return nil }
        let length = zip(path, path.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
        guard length > 60 else { return nil }
        let cx = path.map(\.x).reduce(0, +) / Double(path.count)
        let cy = path.map(\.y).reduce(0, +) / Double(path.count)
        let ds = path.map { hypot($0.x - cx, $0.y - cy) }.sorted()
        let r = max(20, ds[min(ds.count - 1, Int(Double(ds.count) * 0.85))])
        guard r <= maxRadius else { return nil }
        return Anchor(t: t, tEnd: tEnd, x: cx, y: cy, kind: kind, radius: r, key: "o\(t)")
    }

    // MARK: カーソルの動き

    /// 「止まる」の条件。記録中のカーソル表示（満ちていくリング）も同じ値を使う
    static let dwellRadius = 8.0
    static let dwellMinDuration = 0.35

    /// 半径 dwellRadius 以内に dwellMinDuration 秒以上とどまった所を「止まる」とする
    private func detectDwells() -> [Dwell] {
        let s = data.cursor
        var result: [Dwell] = []
        var i = 0
        while i < s.count {
            guard s[i].on else {
                i += 1
                continue
            }
            var j = i + 1
            while j < s.count, s[j].on, hypot(s[j].x - s[i].x, s[j].y - s[i].y) <= Self.dwellRadius { j += 1 }
            let endT = j < s.count ? s[j].t : data.duration
            if endT - s[i].t >= Self.dwellMinDuration {
                let cluster = s[i..<j]
                let x = cluster.map(\.x).reduce(0, +) / Double(cluster.count)
                let y = cluster.map(\.y).reduce(0, +) / Double(cluster.count)
                result.append(Dwell(start: s[i].t, end: endT, x: x, y: y))
            }
            i = j
        }
        return result
    }

    /// 画面の大きな変化を、直前のスクロールの有無で「スクロール」「画面遷移」に分ける
    private func screenEvents() -> [ScreenEvent] {
        data.transitions.map { t in
            let scrolled = data.scrolls.contains { $0 >= t - 0.8 && $0 <= t + 0.3 }
            return ScreenEvent(t: t, kind: scrolled ? .scroll : .transition)
        }
    }

    func samples(from a: Double, to b: Double) -> [CursorSample] {
        data.cursor.filter { $0.t >= a && $0.t <= b && $0.on }
    }

    func position(at t: Double) -> CursorSample? {
        data.cursor.last { $0.t <= t && $0.on }
    }

    func frame(atOrBefore t: Double) -> FrameRecord? {
        data.frames.last { $0.t <= t } ?? data.frames.first
    }

    /// 動きの種類を判定する。長さはポイント。
    func classify(_ s: [CursorSample]) -> (kind: MoveKind, length: Double, duration: Double) {
        guard s.count >= 2 else { return (.still, 0, 0) }
        let length = zip(s, s.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.reduce(0, +)
        let duration = s.last!.t - s.first!.t
        guard length >= 25 else { return (.still, length, duration) }
        let chord = hypot(s.last!.x - s.first!.x, s.last!.y - s.first!.y)

        // 8pt ごとに間引いて、曲がった角度の合計と折り返し回数を数える
        var pts: [(Double, Double)] = [(s[0].x, s[0].y)]
        for p in s.dropFirst() where hypot(p.x - pts.last!.0, p.y - pts.last!.1) >= 8 { pts.append((p.x, p.y)) }

        // 囲む: 中心の周りを 270° 以上回っている
        let cx = pts.map(\.0).reduce(0, +) / Double(pts.count)
        let cy = pts.map(\.1).reduce(0, +) / Double(pts.count)
        var swept = 0.0
        var prevAngle: Double?
        for p in pts where hypot(p.0 - cx, p.1 - cy) > 10 {
            let angle = atan2(p.1 - cy, p.0 - cx)
            if let prev = prevAngle {
                var d = angle - prev
                if d > .pi { d -= 2 * .pi }
                if d < -.pi { d += 2 * .pi }
                swept += d
            }
            prevAngle = angle
        }
        if length > 120, chord < 0.35 * length, abs(swept) > 1.5 * .pi { return (.loop, length, duration) }

        if let far = pts.max(by: { hypot($0.0 - pts[0].0, $0.1 - pts[0].1) < hypot($1.0 - pts[0].0, $1.1 - pts[0].1) }) {
            let ax = far.0 - pts[0].0
            let ay = far.1 - pts[0].1
            let norm = hypot(ax, ay)
            if norm > 30 {
                let proj = pts.map { (($0.0 - pts[0].0) * ax + ($0.1 - pts[0].1) * ay) / norm }
                var reversals = 0
                var extreme = proj[0]
                var dir = 0.0
                for p in proj.dropFirst() {
                    let d = p - extreme
                    if dir == 0 {
                        if abs(d) > 30 { dir = d > 0 ? 1 : -1; extreme = p }
                    } else if (p - extreme) * dir > 0 {
                        extreme = p
                    } else if abs(p - extreme) > 30 {
                        reversals += 1
                        dir = -dir
                        extreme = p
                    }
                }
                if reversals >= 2 { return (.backForth, length, duration) }
            }
        }

        let speed = length / max(duration, 0.01)
        if speed > 1400 { return (.fast, length, duration) }
        if speed < 450, length > 60 { return (.trace, length, duration) }
        return (.move, length, duration)
    }
}
