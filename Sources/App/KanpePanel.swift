import AppKit
import SwiftUI

/// 右側の「カンペ」欄。会議で出た質問への答えを、新しい順にカードで並べる。上の欄から自分でも聞ける。
struct KanpePanel: View {
    @EnvironmentObject private var session: MeetingSession
    /// ⌘K で入力欄にフォーカスを入れるための合図（値が変わるたびにフォーカスする）。
    let focusRequest: Int
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("記憶に聞く（⌘K）", text: $question)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        session.ask(question)
                        question = ""
                    }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 10)

            Toggle("質問に自動で答える（⇧⌘K）", isOn: $session.autoAnswer)
                .disabled(!session.hasAnthropicKey)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)

            if session.answers.isEmpty {
                ContentUnavailableView(
                    "まだ質問はない",
                    systemImage: "lightbulb",
                    description: Text(session.autoAnswer
                        ? "会議で質問が出ると、記憶から答えを探してここに出す。"
                        : "自動の答えは切ってある。⌘K か、字幕の右クリック「これに答えて」で聞ける。")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.answers) { answer in
                            AnswerCard(answer: answer) { session.deepSearch(answer.id) }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // ⌘K で欄を開いたときは、欄ができる前に合図が来るので、表示されたときにも入れる。
        .onAppear { if focusRequest > 0 { DispatchQueue.main.async { focused = true } } }
        .onChange(of: focusRequest) { focused = true }
    }
}

private struct AnswerCard: View {
    let answer: KanpeAnswer
    /// 「もっと探す」（Slack・Notion・Drive などを Claude Code に探させる）。
    let searchDeeper: () -> Void
    @State private var showSources = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(answer.question)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Self.clock.string(from: answer.askedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            switch answer.status {
            case .searching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("記憶を探しています…").foregroundStyle(.secondary)
                }
            case .deepSearching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Slack・Notion・Drive などを探しています…")
                        .foregroundStyle(.secondary)
                }
            case .notFound:
                Label("記憶に見つからなかった", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            case .answered:
                Text(answer.answer)
                    .font(.body)
                    .textSelection(.enabled)
                if !answer.sayEnglish.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Text(answer.sayEnglish)
                            .font(.callout.italic())
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer.sayEnglish, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("英語をコピー")
                    }
                    .padding(8)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                if !answer.sources.isEmpty {
                    DisclosureGroup("根拠 \(answer.sources.count) 件", isExpanded: $showSources) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(answer.sources, id: \.self) { source in
                                Text(source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if answer.status != .searching, answer.status != .deepSearching, !answer.deepSearched {
                Button("もっと探す", systemImage: "sparkle.magnifyingglass", action: searchDeeper)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Claude Code に Slack・Notion・Google ドライブ・カレンダーを探させる")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
