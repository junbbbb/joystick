#!/usr/bin/env swift
//
// Joystick Control Panel — macOS 미니 네이티브 윈도우 (Hot Reload / Hot Restart).
//
// 아무 Flutter 프로젝트나 골라 iOS 시뮬레이터에서 띄우고 Hot Reload / Restart 를
// 버튼으로 제어하는 멀티프로젝트 런처. PTY 로 `flutter run` 을 자식 프로세스로
// 띄우고 버튼 클릭 시 'r' / 'R' 을 stdin 에 직접 전송 — 브라우저 DevTools 와
// 달리 ws idle/throttling 으로 끊길 일이 구조적으로 없다.
//
// 빌드:  ./build.sh        (swiftc + Info.plist + codesign → Joystick.app)
// 실행:  open Joystick.app
//

import Cocoa
import Darwin

let DEFAULT_DEVICE_ID = "E3B0119F-A573-4B3E-8BFE-35857C9A2873"  // iPhone 16 Pro
// 기본 프로젝트도 박제하지 않는다 — 시작 시 discoverProjects() 로 가장 최근
// 작업한 Flutter 프로젝트를 자동 선택한다(없으면 📦 로 직접 고름).
// flutter 경로 역시 런타임에 resolveFlutterBin() 으로 탐색한다 — 설치하는
// 사람마다 위치가 다르므로(다른 맥엔 이 경로가 없다).

extension NSColor {
    static let panelBg = NSColor.white
    static let panelPrimary = NSColor(red: 0.0, green: 0.502, blue: 1.0, alpha: 1)   // #0080FF
    static let panelAccent = NSColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1)     // #FF6B00
    static let panelTextPrimary = NSColor(red: 0.20, green: 0.239, blue: 0.294, alpha: 1)  // #333D4B
    static let panelTextSecondary = NSColor(red: 0.545, green: 0.584, blue: 0.631, alpha: 1)  // #8B95A1
    static let panelTextTertiary = NSColor(red: 0.678, green: 0.71, blue: 0.745, alpha: 1)   // #ADB5BE
    static let panelDivider = NSColor(red: 0.890, green: 0.902, blue: 0.913, alpha: 1)        // #E3E6E9
}

// MARK: - Flutter child process via PTY

final class FlutterRunner {
    private var masterFd: Int32 = -1
    private var process: Process?
    let deviceId: String
    let projectDir: String
    let flutterBin: String

    var onLine: ((String) -> Void)?

    init(deviceId: String, projectDir: String, flutterBin: String) {
        self.deviceId = deviceId
        self.projectDir = projectDir
        self.flutterBin = flutterBin
    }

    /// PROJECT_DIR/.env.local 의 KEY=VALUE 를 flutter `--dart-define` 인자열로
    /// 변환한다. 파일이 없으면 빈 배열. 주석(#)·빈 줄은 건너뛴다 —
    /// scripts/run-dev.sh 의 파싱 규칙과 동일.
    static func dartDefineArgs(projectDir: String) -> [String] {
        let envPath = projectDir + "/.env.local"
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8)
        else {
            return []
        }
        var args: [String] = []
        for rawLine in content.split(separator: "\n",
                                     omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            args.append("--dart-define")
            args.append("\(key)=\(value)")
        }
        return args
    }

    /// flutter 실행파일 경로를 찾는다. GUI 앱(launchd)은 PATH 가 짧아 단순
    /// which 로는 사용자가 .zshrc/fvm 으로 잡아둔 flutter 를 놓친다. 그래서
    /// ① 로그인 셸 PATH 에서 먼저 묻고 ② 안 되면 흔한 설치 경로를 직접 확인.
    static func resolveFlutterBin() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // ① 로그인 셸(-l)이 .zshrc/.zprofile/fvm 을 로드한 뒤의 PATH 에서 탐색.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let found = runLoginShell(shell, "command -v flutter"),
           !found.isEmpty, fm.isExecutableFile(atPath: found) {
            return found
        }

        // ② 흔한 수동/fvm/homebrew 설치 경로를 직접 확인.
        let candidates = [
            home + "/Developer/flutter/bin/flutter",
            home + "/flutter/bin/flutter",
            home + "/development/flutter/bin/flutter",
            home + "/fvm/default/bin/flutter",
            "/opt/homebrew/bin/flutter",
            "/usr/local/bin/flutter",
            "/opt/flutter/bin/flutter",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 로그인 셸로 명령을 실행하고 stdout(trim)을 돌려준다. 사용자의 실제 PATH
    /// 를 반영하려고 -l(로그인) 로 띄운다 — flutter 경로 탐색 전용.
    static func runLoginShell(_ shell: String, _ cmd: String) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", cmd]
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        var master: Int32 = 0
        var slave: Int32 = 0
        let r = openpty(&master, &slave, nil, nil, nil)
        guard r == 0 else {
            onLine?("[error] openpty 실패")
            return
        }
        masterFd = master

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: flutterBin)
        // .env.local 의 KEY=VALUE 를 --dart-define 으로 주입. 이게 없으면
        // String.fromEnvironment(...) 가 전부 빈 문자열이라 PhotoRoom 배경
        // 제거·OAuth·푸시 키가 앱에 안 들어간다 (scripts/run-dev.sh 와 동일 규칙).
        proc.arguments = ["run", "-d", deviceId] + Self.dartDefineArgs(projectDir: projectDir)
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        // launchd 가 GUI 앱에 주는 PATH 는 매우 짧아 cocoapods/git/ruby 가 안 잡힌다.
        // 명시적으로 turnpike 셸에서 쓰는 경로를 끼워준다.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        proc.environment = env
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        do {
            try proc.run()
        } catch {
            onLine?("[error] flutter run 시작 실패: \(error)")
            return
        }
        process = proc
        close(slave)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.readLoop(fd: master)
        }
    }

    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return }
            // flutter run 의 progress 라인은 '\r' 로 같은 줄을 덮어쓰는데, '\n'
            // 만 split 하면 그 라인이 buffer 에 무한 누적되어 status 갱신을
            // 놓친다. CR 을 LF 로 normalize 해서 라인 단위로 처리.
            var chunk = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
            chunk = chunk.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
            pending += chunk
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl])
                pending = String(pending[pending.index(after: nl)...])
                let cleaned = Self.stripAnsi(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    NSLog("[footy-panel] %@", cleaned)
                    DispatchQueue.main.async { [weak self] in self?.onLine?(cleaned) }
                }
            }
        }
    }

    private static func stripAnsi(_ s: String) -> String {
        let pattern = "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -\\/]*[@-~])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    func send(_ ch: String) {
        guard masterFd >= 0 else { return }
        let bytes = Array(ch.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            write(masterFd, ptr.baseAddress, bytes.count)
        }
    }

    func quit() {
        send("q")
        guard let p = process else { return }
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if p.isRunning { p.terminate() }
    }

    var isRunning: Bool { process?.isRunning == true }

    func stop() {
        send("q")
        if let p = process {
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate() }
        }
        if masterFd >= 0 { close(masterFd); masterFd = -1 }
        process = nil
    }
}

// MARK: - Hover-able icon button

final class HoverIconButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var anchorFixed = false
    var hoverBg: NSColor = NSColor(white: 0, alpha: 0.06)
    var pressBg: NSColor = NSColor(white: 0, alpha: 0.12)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fixAnchorToCenter()
    }

    // layer anchor 를 center 로 옮겨야 transform.scale 이 가운데 기준으로 작아진다.
    private func fixAnchorToCenter() {
        guard !anchorFixed, let layer = layer else { return }
        let oldAnchor = layer.anchorPoint
        let new = CGPoint(x: 0.5, y: 0.5)
        let dx = (new.x - oldAnchor.x) * frame.width
        let dy = (new.y - oldAnchor.y) * frame.height
        layer.anchorPoint = new
        layer.position = CGPoint(x: layer.position.x + dx, y: layer.position.y + dy)
        anchorFixed = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        layer?.backgroundColor = hoverBg.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    // 살짝만 눌리는 느낌. 이전 (1.18, 0.72)는 세로 28% 짜부라, super.mouseDown
    // 이 마우스 뗄 때까지 block 하는 동안 그 찌부 상태가 유지돼 — 조금만 오래
    // 눌러도 play.fill/stop.fill 같은 꽉 찬 심볼이 뭉개져 보였다. 폭도 거의
    // 안 늘리고(1.04) 세로도 8%만 줄여(0.92) 누르고 있어도 거슬리지 않게.
    static let pressTransform = CATransform3DMakeScale(1.04, 0.92, 1)

    override func mouseDown(with event: NSEvent) {
        if isEnabled {
            layer?.backgroundColor = pressBg.cgColor
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.06)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer?.transform = Self.pressTransform
            CATransaction.commit()
        }
        super.mouseDown(with: event)  // 사용자가 뗄 때까지 block
        // release: 가볍게 튕겨 복귀. damping 올리고 velocity 0 으로 오버슈트 진정.
        if isEnabled {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: Self.pressTransform)
            spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            spring.damping = 14
            spring.stiffness = 320
            spring.mass = 1
            spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            layer?.transform = CATransform3DIdentity
            layer?.add(spring, forKey: "jelly")
        }
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - Flipped content view

/// 기본 NSView 는 좌하단 원점이라 height 가 늘면 하위 뷰가 위로 밀린다.
/// flipped(좌상단 원점)로 두면 toolbar 는 위에 고정되고 로그가 아래로 펼쳐진다.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Window

final class PanelController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let projectButton: HoverIconButton
    let simButton: HoverIconButton
    let runButton: HoverIconButton
    let stopButton: HoverIconButton
    let reloadButton: HoverIconButton
    let restartButton: HoverIconButton
    let toggleLogButton: HoverIconButton
    let logScrollView: NSScrollView
    let logTextView: NSTextView
    var currentDeviceId: String = DEFAULT_DEVICE_ID
    var currentDeviceName: String = "iPhone 16 Pro"
    var currentProjectPath: String = ""   // 시작 시 자동 선택, 또는 📦 로 선택
    var currentProjectName: String = ""
    var flutterBin: String?
    var runner: FlutterRunner
    var logExpanded = false
    let collapsedHeight: CGFloat = 44
    let expandedHeight: CGFloat = 320

    override init() {
        // VS Code 디버그 툴바처럼 한 줄짜리 슬림 윈도우. 상태는 타이틀바로.
        // 버튼은 아이콘만 (SF Symbol). 토글 시 아래로 로그가 펼쳐진다.
        let winW: CGFloat = 426
        let frame = NSRect(x: 0, y: 0, width: winW, height: 44)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Joystick"
        runner = FlutterRunner(deviceId: DEFAULT_DEVICE_ID, projectDir: "", flutterBin: "")
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .white
        window.level = .floating
        window.isReleasedWhenClosed = false

        let content = FlippedView(frame: frame)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.autoresizesSubviews = false

        // 한 row 아이콘만 — 배경 X, 컬러는 아이콘에만. 6개 색 전부 다름.
        let bw: CGFloat = 44
        let bh: CGFloat = 28
        let pad: CGFloat = 16
        let gap: CGFloat = 6
        func bx(_ i: Int) -> CGFloat { pad + (bw + gap) * CGFloat(i) }

        // 행 맨 앞: 프로젝트 선택. 클릭 → 발견된 Flutter 프로젝트 메뉴 팝업.
        // 프로젝트 고르고 → 시뮬 켜고 → Run, 좌→우 실행 흐름.
        projectButton = Self.makeIconButton(symbol: "shippingbox.fill", color: NSColor.systemIndigo)
        projectButton.frame = NSRect(x: bx(0), y: 8, width: bw, height: bh)
        projectButton.toolTip = "Flutter 프로젝트 선택"
        content.addSubview(projectButton)

        // 시뮬레이터 부팅. 클릭 → 디바이스 메뉴 팝업.
        simButton = Self.makeIconButton(symbol: "iphone", color: NSColor.systemTeal)
        simButton.frame = NSRect(x: bx(1), y: 8, width: bw, height: bh)
        simButton.toolTip = "iPhone 시뮬레이터 부팅"
        content.addSubview(simButton)

        runButton = Self.makeIconButton(symbol: "play.fill", color: NSColor.systemGreen)
        runButton.frame = NSRect(x: bx(2), y: 8, width: bw, height: bh)
        content.addSubview(runButton)

        stopButton = Self.makeIconButton(symbol: "stop.fill", color: NSColor.systemRed)
        stopButton.frame = NSRect(x: bx(3), y: 8, width: bw, height: bh)
        stopButton.isEnabled = false
        content.addSubview(stopButton)

        reloadButton = Self.makeIconButton(symbol: "bolt.fill", color: NSColor.systemBlue)
        reloadButton.frame = NSRect(x: bx(4), y: 8, width: bw, height: bh)
        reloadButton.isEnabled = false
        content.addSubview(reloadButton)

        restartButton = Self.makeIconButton(symbol: "arrow.triangle.2.circlepath", color: NSColor.systemPurple)
        restartButton.frame = NSRect(x: bx(5), y: 8, width: bw, height: bh)
        restartButton.isEnabled = false
        content.addSubview(restartButton)

        toggleLogButton = Self.makeIconButton(symbol: "list.bullet.rectangle", color: NSColor.secondaryLabelColor)
        toggleLogButton.frame = NSRect(x: bx(6), y: 8, width: bw, height: bh)
        content.addSubview(toggleLogButton)

        let quitButton = Self.makeIconButton(symbol: "xmark", color: NSColor.tertiaryLabelColor)
        quitButton.frame = NSRect(x: bx(7), y: 8, width: bw, height: bh)
        content.addSubview(quitButton)

        // 툴바 ↔ 로그 사이 미세 separator
        let sep = NSView(frame: NSRect(x: 0, y: 44, width: winW, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.cgColor
        content.addSubview(sep)

        // 로그 영역 — 평소엔 contentView 위쪽 (보이지 않는 영역)에 숨김. 토글 시 윈도우 height 늘면 자동 노출.
        let logFrame = NSRect(x: 0, y: 45, width: winW, height: expandedHeight - 45)
        logScrollView = NSScrollView(frame: logFrame)
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        logScrollView.borderType = .noBorder
        logScrollView.drawsBackground = true
        logScrollView.backgroundColor = NSColor(white: 0.98, alpha: 1)
        logTextView = NSTextView(frame: NSRect(origin: .zero, size: logFrame.size))
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        logTextView.textColor = .panelTextPrimary
        logTextView.backgroundColor = NSColor(white: 0.98, alpha: 1)
        logTextView.textContainerInset = NSSize(width: 8, height: 8)
        logTextView.minSize = .zero
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.textContainer?.containerSize = NSSize(width: logFrame.width, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = true
        logScrollView.documentView = logTextView
        content.addSubview(logScrollView)

        window.contentView = content

        super.init()
        window.delegate = self

        projectButton.target = self
        projectButton.action = #selector(onProject(_:))
        simButton.target = self
        simButton.action = #selector(onSimulator(_:))
        runButton.target = self
        runButton.action = #selector(onRun)
        stopButton.target = self
        stopButton.action = #selector(onStop)
        reloadButton.target = self
        reloadButton.action = #selector(onReload)
        restartButton.target = self
        restartButton.action = #selector(onRestart)
        toggleLogButton.target = self
        toggleLogButton.action = #selector(onToggleLog)
        quitButton.target = self
        quitButton.action = #selector(onQuit)

        attachRunner()
        // 멀티 프로젝트 런처라 시작 시 자동 실행하지 않는다 —
        // 프로젝트(📦)·시뮬(📱) 고르고 ▶ 를 누르면 그때 resolveDeviceId 로 띄운다.
        setStatus("프로젝트 찾는 중…")
        resolveFlutterBinAsync()
        pickDefaultProjectAsync()
    }

    // 시작 시 가장 최근 작업한 Flutter 프로젝트를 자동 선택한다. 디렉토리 스캔이라
    // 백그라운드로 돌리고 끝나면 타이틀을 갱신. 그 사이 사용자가 📦 로 직접
    // 골랐으면 건드리지 않는다.
    func pickDefaultProjectAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let projects = Self.discoverProjects()
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.currentProjectPath.isEmpty else { return }  // 그새 직접 고름
                if let first = projects.first {
                    self.currentProjectPath = first.path
                    self.currentProjectName = first.name
                    self.appendLog("[project] \(first.name) 자동 선택 — \(first.path)")
                    self.setStatus("준비됨 — ▶ 누르세요")
                } else {
                    self.setStatus("Flutter 프로젝트 못 찾음 — 📦 로 고르세요")
                }
            }
        }
    }

    // flutter 경로는 로그인 셸을 띄워 찾으므로(~0.2초) 백그라운드에서 1회 resolve.
    // 사용자가 프로젝트·시뮬 고르는 사이 끝나 ▶ 누를 땐 보통 준비돼 있다.
    func resolveFlutterBinAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bin = FlutterRunner.resolveFlutterBin()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.flutterBin = bin
                if let bin = bin {
                    self.appendLog("[flutter] \(bin)")
                } else {
                    self.appendLog("[error] flutter 실행파일을 못 찾았어요. PATH·fvm·흔한 경로를 다 봤는데 없네요. CLAUDE.md 의 설치 안내를 참고하세요.")
                    self.setStatus("flutter 못 찾음 — 설치 확인")
                }
            }
        }
    }

    func attachRunner() {
        runner.onLine = { [weak self] line in self?.handleLine(line) }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clampToVisibleFrame()
    }

    // 메뉴바·도크 영역에 윈도우 위/옆이 안 겹치게 visible 영역 안으로 밀어 넣는다.
    func clampToVisibleFrame() {
        guard let screen = window.screen else { return }
        let vis = screen.visibleFrame
        var f = window.frame
        var changed = false
        if f.maxY > vis.maxY { f.origin.y = vis.maxY - f.size.height; changed = true }
        if f.origin.y < vis.minY { f.origin.y = vis.minY; changed = true }
        if f.origin.x < vis.minX { f.origin.x = vis.minX; changed = true }
        if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.size.width; changed = true }
        if changed { window.setFrame(f, display: true, animate: false) }
    }

    func windowDidMove(_ notification: Notification) {
        clampToVisibleFrame()
    }
    func windowDidResize(_ notification: Notification) {
        clampToVisibleFrame()
    }

    @objc func onReload() { runner.send("r") }
    @objc func onRestart() { runner.send("R") }
    @objc func onRun() {
        guard !runner.isRunning else { return }
        guard let flutterBin = flutterBin else {
            appendLog("[error] flutter 경로를 아직 찾는 중이거나 못 찾았어요. 잠깐 뒤 다시 ▶.")
            setStatus("flutter 확인 중…")
            return
        }
        guard !currentProjectPath.isEmpty else {
            appendLog("[error] 실행할 Flutter 프로젝트가 없어요. 📦 버튼으로 하나 고르세요.")
            setStatus("프로젝트 없음 — 📦 로 선택")
            return
        }
        guard let deviceId = resolveDeviceId() else {
            appendLog("[error] 켜진 iPhone 시뮬레이터가 없어요. 📱 버튼으로 하나 부팅한 뒤 다시 ▶.")
            setStatus("시뮬레이터 없음 — 📱 로 부팅")
            return
        }
        runner = FlutterRunner(deviceId: deviceId, projectDir: currentProjectPath, flutterBin: flutterBin)
        attachRunner()
        runner.start()
        setStatus("\(currentDeviceName) 빌드 중…")
        runButton.isEnabled = false
        stopButton.isEnabled = true
        reloadButton.isEnabled = false
        restartButton.isEnabled = false
        appendLog("──── 새 세션 시작 (\(currentProjectName) · \(currentDeviceName)) ────")
    }

    /// 실행할 디바이스를 확정한다. currentDeviceId 가 실제 목록에 있으면 그대로,
    /// 없으면(다른 맥·삭제된 UUID) 부팅된 iPhone → 첫 iPhone 순으로 폴백하고
    /// current 를 갱신한다. 고른 게 꺼져 있으면 부팅까지 해 둔다.
    func resolveDeviceId() -> String? {
        let devices = listIPhoneDevices()
        let chosen = devices.first(where: { $0.udid == currentDeviceId })
            ?? devices.first(where: { $0.isBooted })
            ?? devices.first
        guard let dev = chosen else { return nil }
        currentDeviceId = dev.udid
        currentDeviceName = dev.name
        if !dev.isBooted {
            appendLog("[sim] \(dev.name) 부팅 중…")
            _ = Self.bootSimulator(udid: dev.udid)
        }
        return dev.udid
    }
    @objc func onStop() {
        runner.stop()
        window.title = "Joystick — 중지됨"
        runButton.isEnabled = true
        stopButton.isEnabled = false
        reloadButton.isEnabled = false
        restartButton.isEnabled = false
    }
    @objc func onToggleLog() {
        logExpanded.toggle()
        // collapsedHeight/expandedHeight 는 contentView 기준. window frame 은 titlebar 포함이라
        // 그대로 setFrame 에 넣으면 titlebar 만큼 contentView 가 깎여 toolbar 가 titlebar 와 겹친다.
        let targetContentH = logExpanded ? expandedHeight : collapsedHeight
        var f = window.frame
        let topEdge = f.maxY
        let targetWinH = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: f.width, height: targetContentH)
        ).height
        f.size.height = targetWinH
        f.origin.y = topEdge - targetWinH
        window.setFrame(f, display: true, animate: false)
        clampToVisibleFrame()
        let sym = logExpanded ? "chevron.up" : "list.bullet.rectangle"
        if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolCfg) {
            toggleLogButton.image = img
        }
    }
    @objc func onQuit() {
        runner.quit()
        NSApp.terminate(nil)
    }

    // MARK: - Flutter 프로젝트 선택

    struct FlutterProject {
        let name: String
        let path: String
        let mtime: Date
    }

    // 홈·흔한 상위 폴더의 1-depth 에서 pubspec.yaml(+flutter) 가진 디렉토리를 모은다.
    // pubspec 최근 수정(=최신 작업) 순 정렬 — 방금 만든/건드린 프로젝트가 맨 위.
    static func discoverProjects() -> [FlutterProject] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let roots = [home, home + "/Developer", home + "/Projects",
                     home + "/Documents", home + "/Desktop",
                     home + "/code", home + "/src", home + "/StudioProjects"]
        var found: [FlutterProject] = []
        var seen = Set<String>()
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                if entry.hasPrefix(".") { continue }
                let dir = root + "/" + entry
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                      !seen.contains(dir) else { continue }
                let pubspec = dir + "/pubspec.yaml"
                guard fm.fileExists(atPath: pubspec),
                      fm.fileExists(atPath: dir + "/lib/main.dart"),  // 실행 가능한 앱만(SDK·패키지 제외)
                      let content = try? String(contentsOfFile: pubspec, encoding: .utf8),
                      content.contains("flutter") else { continue }
                let attrs = try? fm.attributesOfItem(atPath: pubspec)
                let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
                found.append(FlutterProject(name: entry, path: dir, mtime: mtime))
                seen.insert(dir)
            }
        }
        found.sort { $0.mtime > $1.mtime }
        return Array(found.prefix(15))  // 최신 15개만 — 메뉴가 너무 길어지지 않게
    }

    @objc func onProject(_ sender: NSButton) {
        let projects = Self.discoverProjects()
        let menu = NSMenu()
        if projects.isEmpty {
            let item = NSMenuItem(title: "Flutter 프로젝트를 찾지 못함", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "최근 작업 순", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let fmt = DateFormatter()
            fmt.dateFormat = "MM/dd HH:mm"
            for p in projects {
                let active = (p.path == currentProjectPath) ? "  ●" : ""
                let item = NSMenuItem(title: "    \(p.name)\(active)      \(fmt.string(from: p.mtime))",
                                      action: #selector(onPickProject(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = ["path": p.path, "name": p.name]
                menu.addItem(item)
            }
        }
        let pos = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: pos, in: sender)
    }

    @objc func onPickProject(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let path = info["path"], let name = info["name"] else { return }
        currentProjectPath = path
        currentProjectName = name
        appendLog("[project] \(name) 선택 — \(path)")
        // 시뮬과 동일: 다음 Run 부터 적용. 실행 중이면 안내만.
        if runner.isRunning {
            setStatus("\(name) — Stop 후 Run 하면 전환")
        } else {
            setStatus("\(name) 준비됨")
        }
    }

    // MARK: - 시뮬레이터 디바이스 선택 / 부팅

    struct SimDevice {
        let name: String
        let udid: String
        let runtime: String   // "iOS 18.5" 형태로 정규화
        let isBooted: Bool
    }

    @objc func onSimulator(_ sender: NSButton) {
        let devices = listIPhoneDevices()
        let menu = NSMenu()
        if devices.isEmpty {
            let item = NSMenuItem(title: "사용 가능한 iPhone 시뮬레이터 없음", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            // runtime 별로 묶어서 헤더 + 항목
            var byRuntime: [String: [SimDevice]] = [:]
            for d in devices { byRuntime[d.runtime, default: []].append(d) }
            let runtimes = byRuntime.keys.sorted(by: >)  // 최신 iOS 위로
            for (idx, rt) in runtimes.enumerated() {
                if idx > 0 { menu.addItem(.separator()) }
                let header = NSMenuItem(title: rt, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for d in byRuntime[rt]! {
                    let mark = d.isBooted ? "  ✓ 켜짐" : ""
                    let active = (d.udid == currentDeviceId) ? "  ●" : ""
                    let item = NSMenuItem(title: "    \(d.name)\(active)\(mark)",
                                          action: #selector(onPickDevice(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = ["udid": d.udid, "name": d.name]
                    menu.addItem(item)
                }
            }
        }
        let pos = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: pos, in: sender)
    }

    @objc func onPickDevice(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let udid = info["udid"], let name = info["name"] else { return }
        currentDeviceId = udid
        currentDeviceName = name
        appendLog("[sim] \(name) 선택 — 부팅 시도")
        setStatus("\(name) 부팅 중…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let booted = Self.bootSimulator(udid: udid)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if booted {
                    self.appendLog("[sim] \(name) 부팅 완료")
                    self.setStatus("\(name) 준비됨")
                } else {
                    self.appendLog("[sim] \(name) 이미 부팅됨 (또는 boot 무시)")
                    self.setStatus("\(name) 사용 가능")
                }
            }
        }
    }

    // 부팅 + Simulator.app 띄움. 이미 부팅이면 simctl boot 가 non-zero exit 하지만 무해.
    static func bootSimulator(udid: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "boot", udid]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let ok = (p.terminationStatus == 0)
        // Simulator.app 자체를 띄워 윈도우가 보이게.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Simulator"]
        try? opener.run()
        return ok
    }

    func listIPhoneDevices() -> [SimDevice] {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "list", "devices", "available", "-j"]
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [SimDevice] = []
        for (rtKey, devs) in dict {
            // "com.apple.CoreSimulator.SimRuntime.iOS-18-5" → "iOS 18.5"
            var rt = rtKey
            if let r = rtKey.range(of: "SimRuntime.") {
                rt = String(rtKey[r.upperBound...])
            }
            rt = rt.replacingOccurrences(of: "iOS-", with: "iOS ")
                   .replacingOccurrences(of: "-", with: ".")
            for d in devs {
                guard let name = d["name"] as? String,
                      let udid = d["udid"] as? String,
                      name.contains("iPhone") else { continue }
                let booted = (d["state"] as? String) == "Booted"
                result.append(SimDevice(name: name, udid: udid, runtime: rt, isBooted: booted))
            }
        }
        result.sort { $0.name < $1.name }
        return result
    }

    func appendLog(_ s: String) {
        let line = s + "\n"
        let attr = NSAttributedString(string: line, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.panelTextPrimary,
        ])
        logTextView.textStorage?.append(attr)
        // cap: 최근 ~600줄만 유지
        if let storage = logTextView.textStorage, storage.length > 60_000 {
            let cut = storage.length - 50_000
            storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        }
        logTextView.scrollToEndOfDocument(nil)
    }

    static let symbolCfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

    static func makeIconButton(symbol: String, color: NSColor) -> HoverIconButton {
        let b = HoverIconButton(title: "", target: nil, action: nil)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.clear.cgColor
        b.layer?.cornerRadius = 12  // 둥글게 — pill 에 가까운 jelly 느낌.
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolCfg) {
            b.image = img
            b.imagePosition = .imageOnly
            b.contentTintColor = color
        }
        return b
    }

    func windowWillClose(_ notification: Notification) {
        runner.quit()
        NSApp.terminate(nil)
    }

    func setStatus(_ s: String) {
        if currentProjectName.isEmpty {
            window.title = "Joystick — \(s)"
        } else {
            window.title = "Joystick · \(currentProjectName) — \(s)"
        }
    }

    func handleLine(_ line: String) {
        appendLog(line)
        // 진행 단계 — 빌드 가시성.
        if line.contains("Running Xcode build") {
            setStatus("Xcode 빌드 중…")
        } else if line.contains("Xcode build done") {
            setStatus("빌드 완료")
        } else if line.contains("Syncing files to device") {
            setStatus("동기화 중…")
        }
        // 활성화 조건은 넓게 — 어느 신호든 들어오면 즉시 활성.
        if line.contains("Flutter run key commands")
            || line.contains("A Dart VM Service")
            || line.contains("Flutter DevTools")
            || line.contains("Hot reload.")
            || line.contains("Hot restart.") {
            setStatus("연결됨")
            reloadButton.isEnabled = true
            restartButton.isEnabled = true
            stopButton.isEnabled = true
            runButton.isEnabled = false
        }
        if line.contains("Performing hot reload") { setStatus("Hot Reload 중…") }
        if line.contains("Performing hot restart") { setStatus("Hot Restart 중…") }
        if line.hasPrefix("Reloaded ") {
            setStatus("Reload 완료")
            reloadButton.isEnabled = true
            restartButton.isEnabled = true
        }
        if line.hasPrefix("Restarted application") {
            setStatus("Restart 완료")
            reloadButton.isEnabled = true
            restartButton.isEnabled = true
        }
        // 에러/예외 신호 — status 에 짧게 띄우고 로그를 펼쳐두면 즉시 보인다.
        if line.lowercased().contains("error") || line.contains("Exception") || line.contains("FAILURE") {
            setStatus("에러 — 로그 확인")
        }
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = PanelController()
app.activate(ignoringOtherApps: true)
controller.show()
app.run()
