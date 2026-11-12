import AppKit
import AVFoundation
import SwiftUI

/// 1 回の会議（開始〜停止）。`MeetingMode` に応じて 1〜2 本のストリーム（システム音声、マイク）を持ち、
/// それぞれを Soniox で文字起こし・翻訳しつつ録音する。
/// 開始ごとに `~/Documents/Kanpe/<日時>/` を作り、`remote.m4a` / `me.m4a` / `room.m4a` と `transcript.md` を保存する。
@MainActor
final class MeetingSession: ObservableObject {
    @Published private(set) var lines: [SubtitleLine] = []
    /// 音源ごとの「話している途中の行」。ハイブリッドでは相手とマイクの 2 本が同時に話すので、
    /// 1 つの変数を取り合うと表示が 2 人の間で行き来してちらつく。
    @Published private(set) var live: [Speaker: SubtitleLine] = [:]
    /// まだ画面に出していない途中の行。2 本の音源の更新を 1 回の反映にまとめる
    /// （同じフレームに何度も変わると SwiftUI が警告を出し、自動スクロールも何度も走る）。
    private var pendingLive: [Speaker: SubtitleLine] = [:]
    private var liveFlushScheduled = false
    @Published private(set) var isRunning = false
    /// 開始の途中（マイクの許可や音源の起動を待っている間）。この間は開始もモードの変更もできない。
    @Published private(set) var isStarting = false
    /// 開始の途中で stop が呼ばれた（終了・エラー）。起動を待っていた音源は、戻ってきたら閉じる。
    private var startCancelled = false
    @Published private(set) var note: String?
    @Published private(set) var hasKey = KeychainStore.soniox.hasKey
    /// 文字起こしをどこでするか。次の開始から効く。
    @Published var backend = TranscriptionBackend.stored {
        didSet { UserDefaults.standard.set(backend.rawValue, forKey: "transcriptionBackend") }
    }
    /// 開始できるか。Soniox で文字起こしするときだけ Soniox のキーが要る。
    var canStart: Bool { backend == .onDevice || hasKey }
    @Published private(set) var folder: URL?
    /// 選択中の context の名前（`ContextLibrary` のファイル名）。nil は「なし」。
    @Published var contextName: String? = UserDefaults.standard.string(forKey: "contextName") {
        didSet { UserDefaults.standard.set(contextName, forKey: "contextName") }
    }
    @Published private(set) var contextNames: [String] = []
    /// 会議の形式。どの音源を使い、マイクを 1 人として扱うか複数人として扱うかが変わる。
    @Published var mode = MeetingMode.stored {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "meetingMode") }
    }
    /// 話者分離のまちがいを手で直した対応（"2" → "1" なら話者 2 を話者 1 として扱う）。
    /// 行には Soniox が返した番号のまま持ち、表示と保存のときに読み替える（取り消せるように）。
    /// キーは `voiceKey`（相手か話者か＋番号）。ハイブリッドでは「相手 2」と「話者 2」は別人なので。
    /// 会議ごとにリセットする。
    @Published private(set) var voiceAliases: [String: String] = [:]
    /// 話者につけた名前。キーは `voiceKey`（読み替え後の番号）。会議ごとにリセットする。
    @Published private(set) var speakerNames: [String: String] = [:]
    /// Claude が割り出した会議の話題（古い順）。Anthropic の API キーがあるときだけ動く。
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var hasAnthropicKey = KeychainStore.anthropic.hasKey
    private var topicTracker: TopicTracker?
    /// 今の会議に渡した用語セット（途中で Anthropic のキーが入ったときに話題の割り出しを始めるため）。
    private var meetingContext: [String: Any]?
    /// 用語セットの `kanpe.project`（なければ用語セットの名前）。記憶を探すときの手がかりにする。
    private var meetingProject: String?
    /// 会議で出た質問へのカンペ（新しい順）。
    @Published private(set) var answers: [KanpeAnswer] = []
    /// 会議で出た質問に自動で答えるか。切っても ⌘K と「これに答えて」では聞ける。
    @Published var autoAnswer = UserDefaults.standard.object(forKey: "autoAnswer") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoAnswer, forKey: "autoAnswer")
            if !autoAnswer { dropPendingAutoAnswers() }
        }
    }
    /// 「カンペに質問…」（⌘K、メニューから）の合図。値が変わるたびに欄を開いて入力欄にフォーカスする。
    @Published var askRequest = 0
    /// 同時に答えを作る数の上限（質問がまとめて来ても API を叩きすぎない）。
    private var answering = 0
    private var answerQueue: [KanpeAnswer] = []
    /// 深掘り検索は重い（claude -p、十数秒〜）ので 1 本ずつ。
    private var deepQueue: [UUID] = []
    private var deepRunning = false
    /// 会議後の再文字起こしの進み具合。nil なら動いていない。
    @Published private(set) var retranscribeStatus: String?
    /// Meet でマイクをミュートしているか。ミュート中はマイクの文字起こしを止める。
    @Published private(set) var micMuted = false
    /// Meet のマイクの見え方（ツールバーの表示用）。nil は見ていない（停止中・対面）。
    @Published private(set) var meetStatus: MeetMuteWatcher.Status?
    private var muteWatcher: MeetMuteWatcher?

    /// 音源 1 本ぶんの部品。
    private final class Stream {
        let speaker: Speaker
        let source: AudioCaptureSource
        let engine: any TranscriptionEngine
        let recorder: AudioFileRecorder
        var assembler = UtteranceAssembler()
        /// この音源が最後に確定した行（遅れて届いた訳文の追記先）。
        var lastLineID: UUID?
        /// endpoint 検出を切っている音源で、間が空いたら行を確定するためのタイマー。
        var idleCommit: Task<Void, Never>?

        init(speaker: Speaker, source: AudioCaptureSource, engine: any TranscriptionEngine, recorder: AudioFileRecorder) {
            self.speaker = speaker
            self.source = source
            self.engine = engine
            self.recorder = recorder
        }
    }

    private var streams: [Stream] = []
    private var transcript: TranscriptFile?

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        startCancelled = false
        defer { isStarting = false }
        note = nil
        let key = KeychainStore.soniox.load() ?? ""
        var context: [String: Any]?
        if let contextName {
            do {
                context = try ContextLibrary.load(contextName)
            } catch {
                note = "context を読めない: \(error.localizedDescription)"
                return
            }
        }
        let startedAt = Date()
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kanpe")
            .appendingPathComponent(Self.folderFormat.string(from: startedAt))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            note = "保存先を作れない: \(error.localizedDescription)"
            return
        }
        self.folder = folder
        transcript = TranscriptFile(url: folder.appendingPathComponent("transcript.md"), startedAt: startedAt)
        lines = []
        voiceAliases = [:]
        speakerNames = [:]
        topics = []
        let split = ContextLibrary.split(context)
        context = split.soniox
        meetingProject = split.project ?? contextName
        meetingContext = context
        answers = []
        answerQueue = []
        deepQueue = []
        if let anthropicKey = KeychainStore.anthropic.load() { startTopicTracker(apiKey: anthropicKey) }

        var problems: [String] = []
        if mode.usesSystemAudio,
           let problem = await startStream(.remote, source: SystemAudioCaptureSource(), language: "en", key: key,
                                     context: context, folder: folder) {
            problems.append("相手: \(problem)")
        }
        if !startCancelled, await Permissions.requestMicrophone(), !startCancelled {
            if let problem = await startStream(mode.micSpeaker, source: MicCaptureSource(), language: "ja", key: key,
                                         context: context, folder: folder) {
                problems.append("マイク: \(problem)")
            }
        } else if !startCancelled {
            problems.append("マイク: 権限が拒否された")
        }
        guard !startCancelled else { return }
        // 開始の途中に届いたエラー（onError）を消さない。
        if !problems.isEmpty { note = problems.joined(separator: " / ") }
        isRunning = !streams.isEmpty
        if isRunning { save() }
        // 相手がシステム音声のとき（オンライン・ハイブリッド）は、Meet のミュートに合わせてマイクを止める。
        if isRunning, mode.usesSystemAudio {
            let watcher = MeetMuteWatcher()
            watcher.onChange = { [weak self] state in self?.setMicMuted(state == .muted) }
            watcher.onStatus = { [weak self] status in self?.meetStatus = status }
            watcher.start()
            muteWatcher = watcher
        }
    }

    /// 失敗したら理由を返す。
    private func startStream(_ speaker: Speaker, source: AudioCaptureSource, language: String,
                             key: String, context: [String: Any]?, folder: URL) async -> String? {
        let engine: any TranscriptionEngine
        switch backend {
        case .soniox:
            // 話者分離と翻訳は複数人の音源だけ。自分（マイク）は 1 人で、自分の発言を日本語に訳す必要もない。
            engine = SonioxTranslationEngine(apiKey: key, sourceLanguage: language, targetLanguage: "ja",
                                             diarization: speaker.isGroup, translate: speaker.isGroup,
                                             context: context,
                                             // Soniox: endpoint 検出は話者分離の精度を下げる。複数人の音源では切り、
                                             // 行は話者の交代と間（idleCommit）で区切る。
                                             endpointDetection: !speaker.isGroup)
        case .onDevice:
            engine = AppleSpeechEngine(language: language)
        }
        let recorder = AudioFileRecorder(folder: folder, name: speaker.recordingName)
        let stream = Stream(speaker: speaker, source: source, engine: engine, recorder: recorder)
        // 録音や音源が途中で死んでも「録音中」のままにならないよう、画面に出す。
        let report: (String) -> Void = { [weak self, weak stream] message in
            Task { @MainActor in
                // 止めたあとに遅れて届いた分を、次の会議に出さない。
                guard let self, let stream, self.streams.contains(where: { $0 === stream }) else { return }
                self.note = message
            }
        }
        recorder.onError = report
        source.onFailure = report
        // 起動を待つ前に登録する：待っている間のエラーと stop()（終了・キャンセル）が、このストリームにも届く。
        streams.append(stream)
        do {
            try await engine.start(
                onTokens: { [weak self] tokens in
                    Task { @MainActor in self?.apply(tokens, to: stream) }
                },
                onError: { [weak self, weak stream] message in
                    Task { @MainActor in
                        guard let self, let stream, self.streams.contains(where: { $0 === stream }) else { return }
                        self.stop()
                        self.note = message
                    }
                }
            )
            // engine は source.start より前に用意する：音源は開始直後からバッファを流す。
            try await Self.startOffMain(source) { [weak engine] buffer in
                engine?.feed(buffer)  // 一時停止中は engine が捨てる
                recorder.append(buffer, silent: engine?.isPaused ?? false)
            }
        } catch {
            streams.removeAll { $0 === stream }
            engine.stop()
            recorder.finish()
            return error.localizedDescription
        }
        return nil
    }

    /// 音源の起動は main の外で待つ。マイク（AirPods Pro）の AVAudioEngine.start は約 3 秒かかった
    /// （2026-10-29 に実測。通話中でも、マイクを先に起動しても同じ）。main で待つとその間ウィンドウが固まる。
    private nonisolated static func startOffMain(_ source: AudioCaptureSource,
                                                 onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try source.start(onBuffer: onBuffer)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        guard isRunning || isStarting else { return }
        if isStarting { startCancelled = true }
        for stream in streams {
            stream.idleCommit?.cancel()
            stream.source.stop()
            stream.engine.stop()
            stream.recorder.finish()
            if var line = stream.assembler.commitPending() {
                line.speaker = stream.speaker
                insert(line)
            }
        }
        streams = []
        muteWatcher?.stop()
        muteWatcher = nil
        micMuted = false
        meetStatus = nil
        topicTracker?.onChange = nil
        topicTracker = nil
        live = [:]
        pendingLive = [:]
        save()
        isRunning = false
    }

    // MARK: - Speaker correction

    /// 音源＋番号のキー（相手 2 と話者 2 を区別する）。
    private func voiceKey(_ speaker: Speaker, _ voice: String) -> String {
        "\(speaker.recordingName):\(voice)"
    }

    /// 表示・保存用に、話者の読み替えを当てた行。
    func display(_ line: SubtitleLine) -> SubtitleLine {
        guard let voice = line.voice else { return line }
        var copy = line
        copy.voice = voiceAliases[voiceKey(line.speaker, voice)] ?? voice
        copy.name = speakerNames[voiceKey(line.speaker, copy.voice!)]
        return copy
    }

    /// その音源で画面に出ている話者番号（読み替え後）。
    func knownVoices(for speaker: Speaker) -> [String] {
        let voices = Set(lines.filter { $0.speaker == speaker }.compactMap { display($0).voice })
        return voices.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
    }

    /// 話者の表示名（名前があれば名前、なければ「話者 2」）。
    func label(_ speaker: Speaker, voice: String) -> String {
        speakerNames[voiceKey(speaker, voice)] ?? "\(speaker.label) \(voice)"
    }

    /// `from` の話者を `into` と同じ人として扱う。`from` に寄せていた番号も `into` に付け替える。
    func mergeVoice(_ speaker: Speaker, _ from: String, into: String) {
        let into = voiceAliases[voiceKey(speaker, into)] ?? into
        guard from != into else { return }
        let fromKey = voiceKey(speaker, from)
        for (key, value) in voiceAliases where key.hasPrefix("\(speaker.recordingName):") && value == from {
            voiceAliases[key] = into
        }
        voiceAliases[fromKey] = into
        save()
    }

    /// 話者に名前をつける。空なら名前を消す。
    func setName(_ name: String, speaker: Speaker, voice: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerNames[voiceKey(speaker, voice)] = trimmed.isEmpty ? nil : trimmed
        save()
    }

    func clearVoiceAliases() {
        voiceAliases = [:]
        save()
    }

    private func save() {
        transcript?.save(lines.map(display), topics: topics)
    }

    // MARK: - Retranscription

    /// 会議フォルダを選ばせて、録音を非同期モデルで文字起こしし直す。複数選べば 1 本にまとめる。
    func chooseAndRetranscribe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = folder?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Kanpe")
        panel.message = "再文字起こしする会議フォルダを選ぶ（複数選ぶと 1 本にまとめる）"
        panel.prompt = "再文字起こし"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        retranscribe(panel.urls)
    }

    private func retranscribe(_ folders: [URL]) {
        guard retranscribeStatus == nil, let key = KeychainStore.soniox.load() else { return }
        var context: [String: Any]?
        if let contextName { context = ContextLibrary.split(try? ContextLibrary.load(contextName)).soniox }
        var job = Retranscriber(sonioxKey: key, anthropicKey: KeychainStore.anthropic.load(), context: context)
        job.progress = { [weak self] message in
            Task { @MainActor in self?.retranscribeStatus = message }
        }
        retranscribeStatus = "準備中"
        Task {
            do {
                let url = try await job.run(folders: folders)
                retranscribeStatus = nil
                NSWorkspace.shared.open(url)
            } catch {
                retranscribeStatus = nil
                note = "再文字起こし失敗: \(error.localizedDescription)"
            }
        }
    }

    func refreshContexts() {
        try? FileManager.default.createDirectory(at: ContextLibrary.folder, withIntermediateDirectories: true)
        contextNames = ContextLibrary.names()
        if let contextName, !contextNames.contains(contextName) { self.contextName = nil }
    }

    func openContextsFolder() {
        refreshContexts()
        NSWorkspace.shared.open(ContextLibrary.folder)
    }

    /// Meet を開いているブラウザを前に出す。
    func showMeet() {
        guard let pid = muteWatcher?.meetPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    private func setMicMuted(_ muted: Bool) {
        micMuted = muted
        for stream in streams where stream.speaker != .remote {
            // 途中の言葉は engine が確定させ、届いた結果で行になる（ここで消さない）。
            stream.engine.setPaused(muted)
        }
    }

    // MARK: - Kanpe (answers)

    /// 質問にカンペを作る。会議中に見つかった質問のほか、自分で聞いたときも使う。
    func ask(_ question: String, lineID: UUID? = nil, auto: Bool = false) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard hasAnthropicKey else {
            note = "Anthropic API Key 未設定（設定 ⌘, で入れる）"
            return
        }
        let entry = KanpeAnswer(question: trimmed, lineID: lineID, askedAt: Date(), auto: auto)
        answers.insert(entry, at: 0)
        answerQueue.append(entry)
        pumpAnswers()
    }

    /// 自動の答えを切ったとき、まだ答えを作り始めていない自動の質問を取り下げる（作り中のものは終わらせ、深掘りはしない）。
    private func dropPendingAutoAnswers() {
        let dropped = Set(answerQueue.filter(\.auto).map(\.id))
        answerQueue.removeAll(where: \.auto)
        answers.removeAll { dropped.contains($0.id) }
    }

    /// 行の内容をそのまま質問として聞く（字幕の右クリックから）。
    func ask(about line: SubtitleLine) {
        let text = line.translation.isEmpty ? line.original : "\(line.original)（\(line.translation)）"
        ask(text, lineID: line.id)
    }

    /// Claude Code に Slack・Notion・Google ドライブ・カレンダーを探させる（カードの「もっと探す」でも呼ぶ）。
    func deepSearch(_ id: UUID) {
        guard let index = answers.firstIndex(where: { $0.id == id }),
              answers[index].status != .deepSearching, !deepQueue.contains(id) else { return }
        answers[index].status = .deepSearching
        deepQueue.append(id)
        pumpDeepSearch()
    }

    private func pumpDeepSearch() {
        guard !deepRunning, !deepQueue.isEmpty else { return }
        let id = deepQueue.removeFirst()
        guard let entry = answers.first(where: { $0.id == id }) else { return pumpDeepSearch() }
        deepRunning = true
        let search = DeepSearch(question: entry.question, project: meetingProject,
                                topic: topics.last, recent: lines.map(display))
        Task {
            defer {
                deepRunning = false
                pumpDeepSearch()
            }
            do {
                let result = try await search.run()
                guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
                answers[index].deepSearched = true
                if result.found {
                    answers[index].status = .answered
                    answers[index].answer = result.answer
                    answers[index].sayEnglish = result.sayEn
                    answers[index].sources = result.sources
                } else {
                    // 深掘りでも見つからない：記憶で見つかっていた答えがあれば残す。記憶を探せなかったなら、その理由を出す。
                    answers[index].status = answers[index].answer.isEmpty
                        ? answers[index].memoryError.map { .failed("記憶を探せなかった：\($0)（Slack などにもなかった）") } ?? .notFound
                        : .answered
                }
            } catch {
                guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
                // 失敗は deepSearched にしない（もっと探すで、もう一度試せるように）。
                if answers[index].answer.isEmpty {
                    let memory = answers[index].memoryError.map { "記憶を探せなかった：\($0) / " } ?? ""
                    answers[index].status = .failed("\(memory)深掘り失敗：\(error.localizedDescription)")
                } else {
                    // 答えは残し、もっと探すをもう一度押せるようにする。
                    answers[index].status = .answered
                    note = "深掘り失敗：\(error.localizedDescription)"
                }
            }
        }
    }

    func answer(for lineID: UUID) -> KanpeAnswer? {
        answers.first { $0.lineID == lineID }
    }

    private func pumpAnswers() {
        while answering < 2, !answerQueue.isEmpty, let key = KeychainStore.anthropic.load() {
            let entry = answerQueue.removeFirst()
            answering += 1
            let engine = AnswerEngine(apiKey: key, project: meetingProject)
            let topic = topics.last
            let recent = lines.map(display)
            Task {
                defer {
                    answering -= 1
                    pumpAnswers()
                }
                // 待っている間に新しい質問が先頭に入るので、書き込む直前に位置を探し直す。
                do {
                    let result = try await engine.answer(question: entry.question, topic: topic, recent: recent)
                    guard let index = answers.firstIndex(where: { $0.id == entry.id }) else { return }
                    if result.found {
                        answers[index].status = .answered
                        answers[index].answer = result.answer
                        answers[index].sayEnglish = result.sayEnglish
                        answers[index].sources = result.sources
                    } else {
                        // 記憶（Cognee）になければ、Slack・Notion・Drive などを深掘りする。
                        answers[index].status = .notFound
                        if !entry.auto || autoAnswer { deepSearch(entry.id) }
                    }
                } catch {
                    guard let index = answers.firstIndex(where: { $0.id == entry.id }) else { return }
                    answers[index].memoryError = error.localizedDescription
                    answers[index].status = .failed(error.localizedDescription)
                    if !entry.auto || autoAnswer { deepSearch(entry.id) }
                }
            }
        }
    }

    /// 開始と停止の切り替え（ツールバーの主操作と ⌘R）。
    func toggleRecording() {
        if isRunning || isStarting { stop() } else { Task { await start() } }
    }

    func clearNote() {
        note = nil
    }

    func openFolder() {
        guard let folder else { return }
        NSWorkspace.shared.open(folder)
    }

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasKey = KeychainStore.soniox.save(trimmed)
        if !hasKey { note = "Soniox API Key を Keychain に保存できない" }
    }

    func saveAnthropicKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasAnthropicKey = KeychainStore.anthropic.save(trimmed)
        guard hasAnthropicKey else {
            note = "Anthropic API Key を Keychain に保存できない"
            return
        }
        // 会議の途中でキーが入ったら、その場で話題の割り出しを始める（入れ直したキーにも切り替える）。
        if isRunning { startTopicTracker(apiKey: trimmed) }
    }

    private func startTopicTracker(apiKey: String) {
        let tracker = TopicTracker(apiKey: apiKey, context: meetingContext, topics: topics)
        tracker.onChange = { [weak self, weak tracker] in
            // 問い合わせ中に停止→次の会議を開始したとき、前の会議の結果を新しい会議に混ぜない。
            guard let self, let tracker, self.topicTracker === tracker else { return }
            self.topics = tracker.topics
            self.save()
        }
        tracker.onQuestions = { [weak self, weak tracker] questions in
            guard let self, let tracker, self.topicTracker === tracker, self.autoAnswer else { return }
            for q in questions { self.ask(q.question, lineID: q.lineID, auto: true) }
        }
        tracker.onError = { [weak self, weak tracker] message in
            guard let self, let tracker, self.topicTracker === tracker else { return }
            self.note = message
        }
        topicTracker?.onChange = nil
        topicTracker = tracker
        tracker.linesDidChange(lines.map(display))
    }

    private func apply(_ tokens: [SonioxResponse.Token], to stream: Stream) {
        // 停止後に届いた分は捨てる（停止時に保存した transcript と画面をずらさない）。
        guard streams.contains(where: { $0 === stream }) else { return }
        handle(stream.assembler.consume(tokens), from: stream)
        if !stream.engine.usesEndpointDetection { scheduleIdleCommit(stream) }
    }

    /// endpoint 検出なしの音源では `<end>` が来ないので、トークンが途切れて少したったら行を確定する。
    private func scheduleIdleCommit(_ stream: Stream) {
        stream.idleCommit?.cancel()
        stream.idleCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.idleCommitDelay)
            guard !Task.isCancelled, let self, self.streams.contains(where: { $0 === stream }) else { return }
            let events = stream.assembler.commitPending().map { [UtteranceAssembler.Event.commit($0)] } ?? []
            self.handle(events, from: stream)
        }
    }

    private static let idleCommitDelay: Duration = .milliseconds(1500)

    private func handle(_ events: [UtteranceAssembler.Event], from stream: Stream) {
        var changed = false
        for event in events {
            switch event {
            case .commit(var line):
                line.speaker = stream.speaker
                insert(line)
                stream.lastLineID = line.id
                changed = true
            case .appendToLast(let translation):
                guard let id = stream.lastLineID,
                      let index = lines.lastIndex(where: { $0.id == id }) else { continue }
                lines[index].translation += translation
                changed = true
            }
        }
        var live = stream.assembler.live
        live.speaker = stream.speaker
        pendingLive[stream.speaker] = live
        if !liveFlushScheduled {
            liveFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.liveFlushScheduled = false
                guard self.isRunning else { return }
                self.live.merge(self.pendingLive) { $1 }
                self.pendingLive = [:]
            }
        }
        if changed {
            save()
            topicTracker?.linesDidChange(lines.map(display))
        }
    }

    /// 発話の開始時刻の順に入れる。長い発言は確定が遅いので、確定順に並べると
    /// その間に挟まった短い相づちより後ろにずれるため。
    private func insert(_ line: SubtitleLine) {
        let index = lines.lastIndex(where: { $0.startedAt <= line.startedAt }).map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
    }
}

/// 会議の形式。
enum MeetingMode: String, CaseIterable {
    /// 相手はシステム音声、マイクは自分 1 人。
    case online
    /// 相手はシステム音声。マイクにも近くの参加者の声が入るので、マイクも話者分離して訳す。
    case hybrid
    /// 全員がマイクに入る。システム音声は使わない。
    case inPerson

    var label: String {
        switch self {
        case .online: "オンライン"
        case .hybrid: "ハイブリッド"
        case .inPerson: "対面"
        }
    }

    var symbol: String {
        switch self {
        case .online: "video"
        case .hybrid: "person.2.badge.plus"
        case .inPerson: "person.2.wave.2"
        }
    }

    var usesSystemAudio: Bool { self != .inPerson }
    /// マイクの音源の扱い。オンライン以外は複数人として話者分離・翻訳する。
    var micSpeaker: Speaker { self == .online ? .me : .room }

    /// 保存された形式。以前の「対面」チェック（inPerson）も読む。
    static var stored: MeetingMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "meetingMode"), let mode = MeetingMode(rawValue: raw) { return mode }
        return defaults.bool(forKey: "inPerson") ? .inPerson : .online
    }
}
