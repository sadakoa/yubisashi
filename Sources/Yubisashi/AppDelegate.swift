import AVFoundation
import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State {
        case idle, starting, recording, processing
    }

    private var state: State = .idle {
        didSet { updateStatusItem() }
    }
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var session: RecordingSession?
    private var overlay: OverlayController?
    private var ticker: Timer?
    private var flash: String?
    private var lastOutput: ReviewBuilder.Output?
    private enum ModelStatus {
        case checking, downloading, ready
        case failed(String)

        var label: String {
            switch self {
            case .checking: L.s("確認中…", "checking…")
            case .downloading: L.s("ダウンロード中…", "downloading…")
            case .ready: L.s("準備済み", "ready")
            case .failed(let message): L.s("未準備（\(message)）", "not ready (\(message))")
            }
        }
    }
    private var modelStatus = ModelStatus.checking

    static let hotKeyLabel = "⌃⌥R"

    /// 記録は貯めず、最新の1件だけをキャッシュに置く（クリップボードの review.md が参照する画像のため）
    private var outputRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yubisashi", isDirectory: true)
    }

    /// 最新の記録以外を消す
    private func pruneOldRecords(keeping latest: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.standardizedFileURL != latest.standardizedFileURL {
            try? fm.removeItem(at: item)
        }
    }

    // MARK: 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()

        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        if hotKey == nil {
            alert(
                L.s(
                    "ホットキー \(Self.hotKeyLabel) を登録できませんでした。ほかのアプリが使っている可能性があります。メニューから記録を開始できます。",
                    "Could not register the \(Self.hotKeyLabel) hotkey. Another app may be using it. You can still start from the menu."))
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        prepareModel()
    }

    private func prepareModel() {
        // 自動のときは日本語と英語の両方のモデルを用意する
        let languages = L.speechMode.fixed.map { [$0] } ?? Lang.allCases
        modelStatus = .checking
        Task { @MainActor in
            var ready = true
            for language in languages where !(await Transcriber.isReady(language)) { ready = false }
            if ready {
                modelStatus = .ready
                return
            }
            modelStatus = .downloading
            do {
                for language in languages { try await Transcriber.prepare(language) }
                modelStatus = .ready
            } catch {
                modelStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: 記録

    @objc private func toggle() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .starting, .processing: NSSound.beep()
        }
    }

    private func startRecording() {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            alert(
                L.s(
                    "画面収録の許可が必要です。\nシステム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 で Yubisashi をオンにしてから、Yubisashi を再起動してください。",
                    "Screen recording permission is needed.\nTurn on Yubisashi in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Yubisashi."),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            alert(
                L.s(
                    "マイクの許可が必要です。\nシステム設定 > プライバシーとセキュリティ > マイク で Yubisashi をオンにしてください。",
                    "Microphone permission is needed.\nTurn on Yubisashi in System Settings > Privacy & Security > Microphone."),
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }

        state = .starting
        let displayID = RecordingSession.displayUnderCursor()
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main!
        overlay?.close()
        let overlay = OverlayController(screen: screen)
        overlay.onStop = { [weak self] in self?.stopRecording() }
        overlay.onDiscard = { [weak self] in self?.cancelRecording() }
        self.overlay = overlay
        overlay.showStarting()
        Task { @MainActor in
            do {
                let session = try await RecordingSession.start(outputRoot: outputRoot, displayID: displayID)
                self.session = session
                state = .recording
                overlay.startRecording(level: { session.audioLevel }, elapsed: { session.elapsed })
                session.excludeCursor { [weak overlay] in overlay?.hudFrameInScreenCoordinates }
                session.caption.onUpdate = { [weak overlay] state in overlay?.updateCaption(state) }
                NSSound(named: "Tink")?.play()
                ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.updateStatusItem()
                }
            } catch {
                overlay.close()
                state = .idle
                alert(L.s("記録を開始できませんでした。", "Could not start recording.") + "\n\(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        // 帯のボタンを素早く2回押しても、1回だけ止める
        guard let session, state == .recording else { return }
        ticker?.invalidate()
        ticker = nil
        state = .processing
        overlay?.showProcessing()
        NSSound(named: "Pop")?.play()
        Task { @MainActor in
            let data = await session.stop()
            self.session = nil
            let output = await ReviewBuilder.build(from: data)
            lastOutput = output
            pruneOldRecords(keeping: output.dir)
            copyToPasteboard(output.markdown)
            state = .idle
            NSSound(named: "Glass")?.play()
            let transcribed = output.transcriptionNote == nil
            showFlash(transcribed ? L.s("コピーしました", "Copied") : L.s("コピーしました（書き起こしなし）", "Copied (no transcript)"))
            overlay?.finish(
                .done(
                    L.s("コピーしました", "Copied"),
                    transcribed
                        ? L.s("Claude Code などに貼り付けてください", "Paste into Claude Code or another coding agent")
                        : L.s("声は書き起こせませんでした", "No speech was transcribed")),
                after: 2.4)
        }
    }

    @objc private func cancelRecording() {
        guard let session, state == .recording else { return }
        ticker?.invalidate()
        ticker = nil
        state = .processing
        overlay?.showProcessing()
        Task { @MainActor in
            await session.cancel()
            self.session = nil
            state = .idle
            showFlash(L.s("破棄しました", "Discarded"))
            overlay?.finish(.cancelled, after: 1.2)
        }
    }

    // MARK: メニューの操作

    @objc private func copyLast() {
        guard let lastOutput else { return }
        copyToPasteboard(lastOutput.markdown)
        showFlash(L.s("コピーしました", "Copied"))
    }

    @objc private func revealLast() {
        guard let lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutput.markdownURL])
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert(L.s("ログイン時の起動を切り替えられませんでした。", "Could not change the login item.") + "\n\(error.localizedDescription)")
        }
    }

    /// 指した UI 要素（ボタン名・DOM の id や class・URL）を記録に入れるため、アクセシビリティの許可を求める
    @objc private func requestAccessibility() {
        ElementProbe.requestTrust()
    }

    static let repositoryURL = URL(string: "https://github.com/sadakoa/yubisashi")!

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(
            string: L.s("指して話すだけで、エージェントに伝わる。\n", "Point and talk to your coding agent.\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(
            NSAttributedString(
                string: "github.com/sadakoa/yubisashi",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Self.repositoryURL]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 表示

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 待機中は見出しを出さない（ホットキーは「記録を開始」の右に出す）。記録中だけ経過時間を見せる
        let header: String?
        switch state {
        case .idle: header = nil
        case .starting: header = L.s("開始しています…", "Starting…")
        case .recording: header = L.s("記録中", "Recording") + " \(formatTime(session?.elapsed ?? 0))"
        case .processing: header = L.s("書き出しています…", "Exporting…")
        }
        if let header {
            let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)
            menu.addItem(.separator())
        }

        switch state {
        case .idle:
            menu.addItem(hotKeyItem(L.s("記録を開始", "Start Recording")))
        case .recording:
            menu.addItem(hotKeyItem(L.s("記録を終了して書き出す", "Stop and Export")))
            menu.addItem(item(L.s("記録を破棄", "Discard Recording"), #selector(cancelRecording)))
        default:
            break
        }
        menu.addItem(.separator())

        let copy = item(L.s("最新の記録をコピー", "Copy Latest Review"), #selector(copyLast))
        copy.isEnabled = lastOutput != nil
        menu.addItem(copy)
        let reveal = item(L.s("最新の記録を Finder で表示", "Show Latest Review in Finder"), #selector(revealLast))
        reveal.isEnabled = lastOutput != nil
        menu.addItem(reveal)
        menu.addItem(.separator())

        // 設定はひとつにまとめ、普段使う項目だけを上に出す
        let settings = NSMenuItem(title: L.s("設定", "Settings"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(languageMenu(L.s("表示言語", "Language"), current: L.lang, action: #selector(selectUILanguage(_:))))
        sub.addItem(speechMenu())
        let model = NSMenuItem(
            title: L.s("音声モデル: ", "Speech model: ") + modelStatus.label,
            action: nil, keyEquivalent: "")
        model.isEnabled = false
        sub.addItem(model)
        sub.addItem(.separator())
        if ElementProbe.isTrusted {
            let probe = NSMenuItem(title: L.s("指した要素の情報: オン", "Element info: on"), action: nil, keyEquivalent: "")
            probe.isEnabled = false
            sub.addItem(probe)
        } else {
            sub.addItem(
                item(
                    L.s("指した要素の情報を取る…（アクセシビリティの許可）", "Capture Element Info… (needs Accessibility)"),
                    #selector(requestAccessibility)))
        }
        let login = item(L.s("ログイン時に起動", "Open at Login"), #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sub.addItem(login)
        settings.submenu = sub
        menu.addItem(settings)
        menu.addItem(item(L.s("Yubisashi について", "About Yubisashi"), #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item(L.s("Yubisashi を終了", "Quit Yubisashi"), #selector(quit)))
    }

    private func languageMenu(_ title: String, current: Lang, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for lang in Lang.allCases {
            let i = item(lang.displayName, action)
            i.representedObject = lang.rawValue
            i.state = lang == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func selectUILanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw) else { return }
        L.lang = lang
        updateStatusItem()
    }

    private func speechMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L.s("話す言語", "Speech"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mode in SpeechMode.allCases {
            let i = item(mode.label, #selector(selectSpeechMode(_:)))
            i.representedObject = mode.rawValue
            i.state = mode == L.speechMode ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func selectSpeechMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = SpeechMode(rawValue: raw) else { return }
        L.speechMode = mode
        prepareModel()
    }

    /// ⌃⌥R を右側に表示する項目（実際の受け付けはグローバルのホットキー）
    private func hotKeyItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(toggle), keyEquivalent: "r")
        i.keyEquivalentModifierMask = [.control, .option]
        i.target = self
        return i
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var title = ""
        var tint: NSColor?
        switch state {
        case .idle:
            symbol = "hand.point.up.left"
        case .starting:
            symbol = "hand.point.up.left.fill"
        case .recording:
            symbol = "record.circle.fill"
            tint = .systemRed
            title = " " + formatTime(session?.elapsed ?? 0)
        case .processing:
            symbol = "hourglass"
            title = L.s(" 書き出し中", " Exporting")
        }
        if let flash, state == .idle { title = " " + flash }

        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Yubisashi")
        if let tint {
            image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.imagePosition = .imageLeading
        button.title = title
    }

    private func showFlash(_ text: String) {
        flash = text
        updateStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard self?.flash == text else { return }
            self?.flash = nil
            self?.updateStatusItem()
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func alert(_ message: String, settingsURL: String? = nil) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Yubisashi"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        if settingsURL != nil { a.addButton(withTitle: L.s("システム設定を開く", "Open System Settings")) }
        if a.runModal() == .alertSecondButtonReturn, let settingsURL, let url = URL(string: settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
