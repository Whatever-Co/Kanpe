import SwiftUI

struct SubtitleView: View {
    @EnvironmentObject private var session: MeetingSession
    @Environment(\.openSettings) private var openSettings
    /// いちばん下を見ているか。見ているときだけ新しい行に自動でついていく（さかのぼって読めるように）。
    @State private var followsLatest = true
    @State private var isAtBottom = true
    @State private var userScrolling = false
    /// 名前をつけている話者の行（シートを出している間だけ）。
    @State private var naming: SubtitleLine?
    /// 右側の「カンペ」欄。質問が来たら開く。会議中に自分で閉じたら、その会議の間は勝手に開かない。
    @State private var showKanpe = false
    @State private var kanpeClosedByUser = false
    @State private var kanpeFocusRequest = 0
    /// ツールバーが全部並ぶ幅（録音中のマイク表示込みで約 715pt）より狭ければまとめる。
    @State private var isCompact = true

    var body: some View {
        VStack(spacing: 0) {
            if let note = session.note { noteBanner(note) }
            transcript
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        // 録音中だけ会議アプリの上に出す。それ以外は普通のウィンドウ。
        .background(WindowLevel(floating: session.isRunning))
        .inspector(isPresented: $showKanpe) {
            KanpePanel(focusRequest: kanpeFocusRequest)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        // まとめた形のツールバーで主操作まで収まる幅（実測）。これより狭いと主操作が溢れて隠れる。
        // リサイズ後なら 512 でも収まるが、起動直後の NSToolbar は 512 では溢れたままになる（2026-10-29）。
        .frame(minWidth: 530)
        // インスペクタの外側で測る。ツールバーはインスペクタの上にも伸びる。
        .onGeometryChange(for: Bool.self) { $0.size.width < 740 } action: { isCompact = $0 }
        .onChange(of: session.answers.count) { old, new in
            if new > old, !kanpeClosedByUser { showKanpe = true }
        }
        .onChange(of: session.askRequest) {
            showKanpe = true
            kanpeClosedByUser = false
            kanpeFocusRequest += 1
        }
        .onChange(of: session.isRunning) { _, running in
            if running { kanpeClosedByUser = false }
        }
        .sheet(item: $naming) { line in
            NameSheet(label: line.label, initial: line.name ?? "") { name in
                if let voice = line.voice {
                    session.setName(name, speaker: line.speaker, voice: voice)
                }
                naming = nil
            } cancel: {
                naming = nil
            }
        }
        .onAppear {
            session.refreshContexts()
            if !session.canStart { openSettings() }
        }
    }

    // MARK: - Title

    /// HIG：アプリ名ではなく、いまの状態を短く（15 字以内）。話題は本文のセクション見出しに出す。
    private var title: String {
        session.isRunning ? "録音中" : "待機中"
    }

    private var subtitle: String {
        if let status = session.retranscribeStatus { return "再文字起こし：\(status)" }
        let mode = session.mode.label
        let terms = session.contextName.map { " · 用語セット：\($0)" } ?? ""
        return mode + terms
    }

    // MARK: - Toolbar

    /// HIG に合わせて 3 つのグループ：会議の設定／補助の操作／主操作（右端、prominent）。
    /// 狭いウィンドウでは、モードをメニューに、補助の操作を「その他」メニューにまとめる。
    /// ツールバーは右端から溢れるので、まとめないと主操作が真っ先に隠れる。
    /// 狭くて録音中なら、モードのメニュー（録音中は変えられない）の場所にマイク表示を出す。
    /// 項目が増えないので、録音を始めてもウィンドウの最小幅が変わらない。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if isCompact, let status = session.meetStatus {
                meetStatusView(status)
            } else if isCompact {
                Menu {
                    modePicker.pickerStyle(.inline)
                } label: {
                    Label(session.mode.label, systemImage: session.mode.symbol)
                }
                .disabled(session.isRunning || session.isStarting)
                .help("オンライン：相手はシステム音声、マイクは自分だけ／ハイブリッド：近くの参加者の声もマイクに入る／対面：マイクだけ")
            } else {
                // モードの切り替えなのでセグメント（トグルだとオンの色が主操作と競う）。
                modePicker
                    .pickerStyle(.segmented)
                    .disabled(session.isRunning || session.isStarting)
                    .help("オンライン：相手はシステム音声、マイクは自分だけ／ハイブリッド：近くの参加者の声もマイクに入る／対面：マイクだけ")
            }
            contextMenu
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            // 狭いときは出さない（進捗はサブタイトルにある）。増えると主操作が溢れる。
            if !isCompact, let status = session.retranscribeStatus {
                ProgressView()
                    .controlSize(.small)
                    .help(status)
            }
            if isCompact {
                Menu {
                    secondaryActions
                } label: {
                    Label("その他", systemImage: "ellipsis.circle")
                }
                .help("再文字起こし・保存フォルダ・カンペ")
            } else {
                secondaryActions
            }
        }

        if !isCompact, let status = session.meetStatus {
            ToolbarItem { meetStatusView(status) }
        }

        ToolbarSpacer(.fixed)

        ToolbarItem {
            Button {
                session.toggleRecording()
            } label: {
                Label(session.isRunning || session.isStarting ? "停止" : "開始",
                      systemImage: session.isRunning || session.isStarting ? "stop.fill" : "record.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .tint(session.isRunning || session.isStarting ? .red : .accentColor)
            .disabled(!session.canStart)
            .help(session.isRunning || session.isStarting ? "停止（⌘R）" : "開始（⌘R）")
        }
    }

    private var modePicker: some View {
        Picker("会議の形式", selection: $session.mode) {
            ForEach(MeetingMode.allCases, id: \.self) { mode in
                Label(mode.label, systemImage: mode.symbol).tag(mode)
            }
        }
    }

    /// 補助の操作。広いときはツールバーに並べ、狭いときは「その他」メニューの中身になる。
    @ViewBuilder
    private var secondaryActions: some View {
        if session.retranscribeStatus == nil {
            Button {
                session.chooseAndRetranscribe()
            } label: {
                Label("再文字起こし", systemImage: "text.badge.checkmark")
            }
            .help("会議の後で録音を文字起こしし直す（話者分離が正確になる）")
            .disabled(session.isRunning || !session.hasKey)
        }
        Button {
            session.openFolder()
        } label: {
            Label("保存フォルダ", systemImage: "folder")
        }
        .help("保存フォルダを開く")
        .disabled(session.folder == nil)
        Button {
            showKanpe.toggle()
            kanpeClosedByUser = !showKanpe
            if showKanpe { kanpeFocusRequest += 1 }
        } label: {
            // 自動の答えを切っているときは斜線つき。
            Label("カンペ", systemImage: session.autoAnswer ? "lightbulb" : "lightbulb.slash")
        }
        .help(session.autoAnswer
            ? "カンペ：会議で出た質問に自動で答える（⌘K で質問、⇧⌘K で自動を切る）"
            : "カンペ：自動の答えは切ってある（⌘K で質問、⇧⌘K で自動に戻す）")
    }

    /// 会議アプリ（Zoom・Meet）のマイクの状態。ミュート中はマイクの文字起こしを止めている。
    /// アイコンごとに幅が違うので枠を固定する（切り替わるたびにツールバーがずれないように）。
    @ViewBuilder
    private func meetStatusView(_ status: MeetMuteWatcher.Status) -> some View {
        switch status {
        case .muted:
            meetIcon("mic.slash.fill", color: .red, help: "会議アプリでミュート中。マイクの文字起こしを止めている")
        case .unmuted:
            meetIcon("mic.fill", color: .primary, help: "会議アプリでマイクがオン。マイクも文字起こししている")
        case .notFound:
            meetIcon("mic.badge.xmark", color: .secondary,
                     help: "Zoom の会議も Meet のマイクボタンも見つからない。Meet はタブを前に出すと見つかることがある")
        case .noPermission:
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } label: {
                Label("アクセシビリティの許可が必要", systemImage: "lock.shield")
            }
            .help("Zoom・Meet のミュートを読むには、システム設定で Kanpe にアクセシビリティを許可する")
        }
    }

    /// ほかのツールバー項目と同じ大きさになるよう、画像ではなくボタンにする（押すと会議アプリを前に出す）。
    private func meetIcon(_ symbol: String, color: Color, help: String) -> some View {
        Button {
            session.showMeet()
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20, alignment: .center)
        }
        .help(help + "（押すと会議アプリを前に出す）")
        .accessibilityLabel(help)
    }

    /// 用語セットの選択。開始時に Soniox へ送るので、会議中は変えられない。
    private var contextMenu: some View {
        Menu {
            ContextMenuItems()
        } label: {
            Label(session.contextName ?? "用語なし", systemImage: "character.book.closed")
        }
        .disabled(session.isRunning || session.isStarting)
        .help("用語セット：\(session.contextName ?? "なし")（~/Documents/Kanpe/Contexts/*.json）")
    }

    /// エラーなどの通知。ツールバーには置かず、本文の上に出す。
    private func noteBanner(_ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(note)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button {
                session.clearNote()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("閉じる")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    /// 字幕の流れ。話題ごとのセクションに分け、見出しはスクロール位置の話題が上に貼り付く（HTML レポートと同じ）。
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    let sections = self.sections
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        Section {
                            ForEach(section.lines) { line in
                                let shown = session.display(line)
                                LineView(line: shown, isLive: false) { voiceMenu(for: shown) }
                                    .padding(.horizontal, 12)
                                    .overlay(alignment: .topTrailing) {
                                        // 質問として拾われた行には印。押すとカンペ欄を開く。
                                        if session.answer(for: line.id) != nil {
                                            Button {
                                                showKanpe = true
                                                kanpeClosedByUser = false
                                            } label: {
                                                Image(systemName: "lightbulb.fill")
                                                    .foregroundStyle(.yellow)
                                            }
                                            .buttonStyle(.borderless)
                                            .padding(.trailing, 14)
                                            .help("この質問へのカンペを見る")
                                        }
                                    }
                            }
                            if index == sections.count - 1 { liveLines }
                        } header: {
                            if let topic = section.topic {
                                topicHeader(topic, number: section.number)
                            }
                        }
                    }
                    if sections.isEmpty { liveLines }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                isAtBottom = atBottom
                if atBottom {
                    followsLatest = true
                } else if userScrolling {
                    followsLatest = false
                }
            }
            .onScrollPhaseChange { _, phase in
                // 追従を止めるのは手でスクロールしたときだけ（行が増えて下が伸びただけでは止めない）。
                userScrolling = phase == .interacting || phase == .decelerating
                if userScrolling && !isAtBottom { followsLatest = false }
            }
            .onChange(of: session.lines.count) { followLatest(proxy) }
            .onChange(of: session.live) { followLatest(proxy) }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button {
                        followsLatest = true
                        withAnimation { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Label("最新へ", systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private var liveLines: some View {
        // ID は音源で固定する（行の ID は更新のたびに変わるので、それで識別すると毎回作り直されてちらつく）。
        ForEach(Speaker.allCases, id: \.self) { speaker in
            if let live = session.live[speaker], !live.original.isEmpty || !live.translation.isEmpty {
                LineView(line: session.display(live), isLive: true) { EmptyView() }
                    .padding(.horizontal, 12)
            }
        }
    }

    private struct TopicSection {
        let topic: Topic?
        /// 何個目の話題か（1 始まり）。話題の前の区間は 0。
        let number: Int
        var lines: [SubtitleLine]
    }

    /// 話題の開始時刻で行を区切る。最初の話題より前の行は見出しなしの区間。
    private var sections: [TopicSection] {
        var sections = [TopicSection(topic: nil, number: 0, lines: [])]
        var pending = session.topics[...]
        for line in session.lines {
            while let topic = pending.first, topic.startedAt <= line.startedAt {
                sections.append(TopicSection(topic: topic, number: sections.count, lines: []))
                pending = pending.dropFirst()
            }
            sections[sections.count - 1].lines.append(line)
        }
        // まだ行のない最新の話題も出す（話題が先に決まり、行がこれから来る）。
        for topic in pending { sections.append(TopicSection(topic: topic, number: sections.count, lines: [])) }
        return sections.filter { $0.topic != nil || !$0.lines.isEmpty }
    }

    /// 話題の見出し。スクロールすると、いま見ている位置の話題が上に貼り付く。
    private func topicHeader(_ topic: Topic, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.clock.string(from: topic.startedAt))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.tint)
                Text(topic.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(number) / \(session.topics.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(topic.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func followLatest(_ proxy: ScrollViewProxy) {
        guard followsLatest else { return }
        proxy.scrollTo(bottomID, anchor: .bottom)
    }

    private let bottomID = "bottom"

    /// 話者分離のまちがいを直すメニュー。「話者 2 は 話者 1 と同じ」を選ぶと、その会議の間ずっと読み替える。
    @ViewBuilder
    private func voiceMenu(for line: SubtitleLine) -> some View {
        if let voice = line.voice {
            Button("これに答えて") {
                session.ask(about: line)
                showKanpe = true
                kanpeClosedByUser = false
            }
            Divider()
            Button("名前をつける…") { naming = line }
            if line.name != nil {
                Button("名前を消す") { session.setName("", speaker: line.speaker, voice: voice) }
            }
            let others = session.knownVoices(for: line.speaker).filter { $0 != voice }
            if !others.isEmpty { Divider() }
            ForEach(others, id: \.self) { other in
                Button("\(line.label) は \(session.label(line.speaker, voice: other)) と同じ") {
                    session.mergeVoice(line.speaker, voice, into: other)
                }
            }
        }
        if !session.voiceAliases.isEmpty {
            Divider()
            Button("話者の統合をすべて戻す") { session.clearVoiceAliases() }
        }
    }

}

private struct LineView<VoiceMenu: View>: View {
    let line: SubtitleLine
    let isLive: Bool
    /// アバターを右クリックしたときのメニュー（答え・名前・話者の統合）。
    @ViewBuilder let voiceMenu: () -> VoiceMenu

    var body: some View {
        if line.speaker == .me {
            // 自分の発言は言ったままを小さく、ラベル付きで出す。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(line.original)
                    .font(.system(size: 13))
                    .foregroundStyle(isLive ? .tertiary : .secondary)
            }
            .textSelection(.enabled)
        } else {
            let style = line.voice.map { VoiceStyle(voice: $0, speaker: line.speaker) }
            HStack(alignment: .top, spacing: 8) {
                if let style {
                    // 右クリックで名前と統合のメニュー。
                    BotAvatar(shape: style.shape, color: style.color, size: 26)
                        .opacity(isLive ? 0.5 : 1)
                        .contentShape(Rectangle())
                        .contextMenu { if !isLive { voiceMenu() } }
                        .help("右クリック：名前をつける・別の話者と統合")
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let style {
                        Text(line.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(style.color)
                    }
                    // 訳があれば訳を大きく、原文を小さく。訳がない（日本語の発言）なら原文を大きく。
                    let main = line.translation.isEmpty ? line.original : line.translation
                    Group {
                        if !main.isEmpty {
                            Text(main)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(isLive ? .secondary : .primary)
                        }
                        if !line.translation.isEmpty && !line.original.isEmpty {
                            Text(line.original)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 話者の名前を入力するシート。表示したら入力欄にフォーカスを入れる。
private struct NameSheet: View {
    let label: String
    let save: (String) -> Void
    let cancel: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(label: String, initial: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.label = label
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(label) の名前").font(.headline)
            TextField("名前", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit { save(name) }
            Text("この会議の間、表示と記録に使う。空にすると名前を消す。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }
}

/// ホストしている NSWindow の level を切り替える。SwiftUI の `.windowLevel` はシーンに一度
/// 決めるだけで、録音の状態に合わせて変えられないため。
private struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // ビューがウィンドウに載るのは次のループなので、そこで設定する。
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}
