import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--demo") {
    let root =
        CommandLine.arguments.count > i + 1
        ? URL(fileURLWithPath: CommandLine.arguments[i + 1])
        : FileManager.default.temporaryDirectory
    Task {
        do {
            let url = try await Demo.run(outputRoot: root)
            print(url.path)
            exit(0)
        } catch {
            FileHandle.standardError.write("demo failed: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// 開発用: コンセプト動画を作る（言語を省くと日本語と英語の両方）
if let i = CommandLine.arguments.firstIndex(of: "--concept-video"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let langs: [Lang] =
        CommandLine.arguments.count > i + 2 ? [Lang(rawValue: CommandLine.arguments[i + 2]) ?? .ja] : [.ja, .en]
    Task {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for lang in langs {
                let url = try await ConceptVideo.run(outputDir: dir, lang: lang)
                print(url.path)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("concept video failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

// 開発用: 「スクショ＋文章」と「Yubisashi の記録」を比べる素材を作る
if let i = CommandLine.arguments.firstIndex(of: "--eval-materials"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    Task {
        do {
            try await EvalMaterials.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write("eval materials failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--caption-test"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    Task {
        do {
            try await CaptionTest.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write("caption test failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--reanalyze"), CommandLine.arguments.count > i + 1,
    CommandLine.arguments.contains("--retranscribe")
{
    _ = NSApplication.shared
    Task {
        do {
            try await Reanalyze.runRetranscribing(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write("reanalyze failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--reanalyze"), CommandLine.arguments.count > i + 1 {
    do {
        try Reanalyze.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write("reanalyze failed: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--overlay-snapshot"), CommandLine.arguments.count > i + 1 {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        do {
            try OverlaySnapshot.run(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

// 開発用: 記録はせず、記録中の表示だけを数秒出す
if CommandLine.arguments.contains("--overlay-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let screen = NSScreen.screens.first { $0.displayID == RecordingSession.displayUnderCursor() } ?? NSScreen.main!
    let overlay = OverlayController(screen: screen)
    overlay.showStarting()
    let start = CACurrentMediaTime()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        overlay.startRecording(
            level: { max(0, sin((CACurrentMediaTime() - start) * 3)) * 0.8 },
            elapsed: { CACurrentMediaTime() - start })
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { overlay.showProcessing() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
        overlay.finish(.done(L.s("コピーしました", "Copied"), L.s("Claude Code などに貼り付けてください", "Paste into Claude Code or another coding agent")), after: 1.5)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { exit(0) }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
