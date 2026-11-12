import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "co.whatever.Kanpe", category: "MeetMuteWatcher")

/// Zoom アプリか、ブラウザで開いている Google Meet のマイクのミュート状態を、アクセシビリティ経由で読む。
///
/// Zoom は会議中だけメニューに「オーディオをミュート」（話せる状態）/「オーディオのミュートを解除」
/// （ミュート中）が出るので、それを読む。Meet のマイクボタンは状態で名前が変わる（ミュート中は
/// 「マイクをオン」、話せる状態では「マイクをオフ」）。1 秒ごとに読み、Zoom を先に見る。
/// Kanpe にアクセシビリティの許可が要る。Chromium 系のブラウザは、`AXManualAccessibility` を
/// 立てるまでページの中身を出さない。
@MainActor
final class MeetMuteWatcher {
    enum State: Equatable {
        case muted
        case unmuted
        /// 会議が見つからない（Zoom の会議中でも Meet のタブを開いているわけでもない）。
        case unknown
    }

    /// 見えている状態（画面表示用）。
    enum Status: Equatable {
        case noPermission
        case notFound
        case muted
        case unmuted
    }

    /// ミュート状態が変わったとき（見失っても直前の状態を保つ）。
    var onChange: ((State) -> Void)?
    /// 見えている状態が変わったとき（許可なし・見つからないも含む）。
    var onStatus: ((Status) -> Void)?
    private(set) var state = State.unknown
    private var status: Status?
    /// 会議を見つけたアプリ（Zoom かブラウザ）のプロセス（ツールバーのボタンで前に出すため）。
    private(set) var meetPID: pid_t?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "co.whatever.Kanpe.meetMute")
    /// 前回見つけたマイクボタン。毎回ページ全体を探さずに済むよう、まずこれを読む（`queue` 上でだけ触る）。
    nonisolated(unsafe) private var cachedButton: AXUIElement?
    /// `cachedButton` を見つけたブラウザ（Zoom を挟んでも、Meet に戻ったとき正しいアプリを前に出すため）。
    nonisolated(unsafe) private var cachedButtonPID: pid_t?
    nonisolated(unsafe) private var foundPID: pid_t?
    /// アクセシビリティを有効にしたブラウザ（1 度だけ設定し、止めたら AXEnhancedUserInterface を戻す。`queue` 上でだけ触る）。
    nonisolated(unsafe) private var enabledPIDs = Set<pid_t>()
    /// stop の後片付けが済んだ（そのあとに残りの読み取りが走っても、属性を立て直さない。`queue` 上でだけ触る）。
    nonisolated(unsafe) private var halted = false
    /// 前の読み取りが終わっていない（ページ全体を探すと 1 秒を超えることがあり、積み上がるため）。
    private var polling = false

    private static let zoomBundleID = "us.zoom.xos"
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.apple.Safari",
    ]
    // 2026-10-21 に Arc で見た実際の名前は「マイクをオン」。「マイクをオンにする」などもこれで拾える。
    private static let mutedLabels = ["マイクをオン", "turn on microphone", "unmute"]
    private static let unmutedLabels = ["マイクをオフ", "turn off microphone"]

    func start() {
        // 許可がなければダイアログを出す（許可されるまでは unknown のまま）。
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            log.notice("meeting mic: accessibility permission not granted yet")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
        onStatus = nil
        // AXEnhancedUserInterface が立ったままだとウィンドウの移動・リサイズのアニメーションが崩れる。
        queue.async { [self] in
            for pid in enabledPIDs {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
            }
            enabledPIDs = []
            halted = true
        }
    }

    private func report(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatus?(new)
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            report(.noPermission)
            return
        }
        guard !polling else { return }
        polling = true
        let apps = NSWorkspace.shared.runningApplications
        let zoomPIDs = apps.filter { $0.bundleIdentifier == Self.zoomBundleID }.map(\.processIdentifier)
        let pids = apps.filter { Self.browsers.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier)
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.readState(zoomPIDs: zoomPIDs, pids: pids)
            let pid = self.foundPID
            Task { @MainActor in
                self.polling = false
                if found != .unknown { self.meetPID = pid }
                self.update(found)
            }
        }
    }

    private func update(_ new: State) {
        switch new {
        case .muted: report(.muted)
        case .unmuted: report(.unmuted)
        case .unknown: report(.notFound)
        }
        // 見失ったとき（別のタブに切り替えたなど）は直前の状態を保つ。ミュートしたまま
        // タブを移ったとたんに文字起こしが再開しないように。
        guard new != .unknown, new != state else { return }
        state = new
        log.notice("meeting mic: \(new == .muted ? "muted" : "unmuted", privacy: .public)")
        onChange?(new)
    }

    // MARK: - Accessibility（queue 上）

    nonisolated private func readState(zoomPIDs: [pid_t], pids: [pid_t]) -> State {
        guard !halted else { return .unknown }
        for pid in zoomPIDs {
            if let state = zoomState(pid) {
                foundPID = pid
                return state
            }
        }
        if let button = cachedButton, let state = Self.state(of: button) {
            foundPID = cachedButtonPID
            return state
        }
        cachedButton = nil
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            if enabledPIDs.insert(pid).inserted {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            for window in Self.children(app, attribute: kAXWindowsAttribute) {
                // Arc はサイドバーに要素が多いので、先に Meet のページ（Web エリア）を探して、その中だけ調べる。
                let areas = Self.find(in: window, limit: 20000) { element in
                    Self.string(element, kAXRoleAttribute) == "AXWebArea"
                }
                for area in areas where (Self.url(area) ?? "").contains("meet.google.com") {
                    let buttons = Self.find(in: area, limit: 20000) { element in
                        Self.string(element, kAXRoleAttribute) == kAXButtonRole as String && Self.state(of: element) != nil
                    }
                    if let button = buttons.first {
                        cachedButton = button
                        cachedButtonPID = pid
                        foundPID = pid
                        return Self.state(of: button) ?? .unknown
                    }
                }
            }
        }
        return .unknown
    }

    /// Zoom のメニューバーから、ミュートの項目を探して読む。会議中でなければ nil。
    /// メニュー項目名はログに出さない（Window メニューには会議名の入ったウィンドウ名が並ぶ）。
    nonisolated private func zoomState(_ pid: pid_t) -> State? {
        let app = AXUIElementCreateApplication(pid)
        // Zoom が固まっていても、Meet の読み取りまで待たせない。
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) == .success,
              let menuBar = value, CFGetTypeID(menuBar) == AXUIElementGetTypeID() else { return nil }
        for barItem in Self.children(menuBar as! AXUIElement, attribute: kAXChildrenAttribute) {
            for menu in Self.children(barItem, attribute: kAXChildrenAttribute) {
                for item in Self.children(menu, attribute: kAXChildrenAttribute) {
                    guard let title = Self.string(item, kAXTitleAttribute)?.lowercased() else { continue }
                    if let state = Self.zoomState(title: title) { return state }
                }
            }
        }
        return nil
    }

    /// 自分のオーディオの項目だけを見る（「参加者のオーディオをミュート」「すべてミュート」などと取り違えない）。
    nonisolated private static func zoomState(title: String) -> State? {
        if title.hasPrefix("unmute audio") || title.hasPrefix("unmute my audio")
            || (title.hasPrefix("オーディオ") && title.contains("ミュート") && title.contains("解除")) { return .muted }
        if title.hasPrefix("mute audio") || title.hasPrefix("mute my audio")
            || (title.hasPrefix("オーディオ") && title.contains("ミュート")) { return .unmuted }
        return nil
    }

    nonisolated private static func state(of element: AXUIElement) -> State? {
        let label = [string(element, kAXDescriptionAttribute), string(element, kAXTitleAttribute)]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if mutedLabels.contains(where: { label.contains($0) }) { return .muted }
        if unmutedLabels.contains(where: { label.contains($0) }) { return .unmuted }
        return nil
    }

    /// 幅優先で条件に合う要素を集める。重くならないよう、調べる要素の数に上限をつける。
    nonisolated private static func find(in root: AXUIElement, limit: Int,
                                         where match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var queue = [root]
        var index = 0
        var found: [AXUIElement] = []
        while index < queue.count, index < limit {
            let element = queue[index]
            index += 1
            if match(element) {
                found.append(element)
                continue // 見つけた要素の中には入らない
            }
            queue += children(element, attribute: kAXChildrenAttribute)
        }
        return found
    }

    nonisolated private static func url(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        return (value as? URL)?.absoluteString ?? value as? String
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func children(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
