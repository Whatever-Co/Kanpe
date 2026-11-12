import SwiftUI

/// 設定ウィンドウ（⌘,）。API キーはキーチェーンに保存し、画面には出さない。
/// 開いたときと保存したときに、キーが実際に使えるかを確かめて表示する。
struct SettingsView: View {
    @EnvironmentObject private var session: MeetingSession
    @State private var sonioxKey = ""
    @State private var anthropicKey = ""
    @State private var sonioxCheck = KeyCheck.missing
    @State private var anthropicCheck = KeyCheck.missing

    var body: some View {
        Form {
            Section {
                Picker("文字起こし", selection: $session.backend) {
                    ForEach(TranscriptionBackend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Mac 内はキー不要で、音声が Mac の外に出ない。翻訳と話者の聞き分けはしない。次の開始から切り替わる。")
            }
            Section {
                keyField("Soniox", text: $sonioxKey, check: sonioxCheck) {
                    session.saveKey(sonioxKey)
                    sonioxKey = ""
                    Task { await verifySoniox() }
                }
            } footer: {
                Text("Soniox での文字起こし・翻訳と、会議後の再文字起こしに使う。")
            }
            Section {
                keyField("Anthropic", text: $anthropicKey, check: anthropicCheck) {
                    session.saveAnthropicKey(anthropicKey)
                    anthropicKey = ""
                    Task { await verifyAnthropic() }
                }
            } footer: {
                Text("話題の割り出し・カンペの答え・再文字起こしの話題整理に使う。なくても翻訳は動く。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            async let soniox: Void = verifySoniox()
            async let anthropic: Void = verifyAnthropic()
            _ = await (soniox, anthropic)
        }
    }

    private func keyField(_ name: String, text: Binding<String>, check: KeyCheck,
                          save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("\(name) API Key") {
                HStack {
                    // Form の中では最初の引数はラベル扱いになるので、プレースホルダーは prompt で渡す。
                    SecureField("\(name) API Key", text: text,
                                prompt: Text(check == .missing ? "未設定" : "変更するときだけ入力"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onSubmit(save)
                    Button("保存", action: save)
                        .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            status(check)
        }
    }

    @ViewBuilder
    private func status(_ check: KeyCheck) -> some View {
        switch check {
        case .missing:
            Label("未設定", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("確認中…").foregroundStyle(.secondary)
            }
        case .ok:
            Label("使える", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    // キーチェーンの読み出しはメインスレッドの外で行う（Security が警告を出すため）。
    private func verifySoniox() async {
        sonioxCheck = .checking
        guard let key = await Task.detached(operation: { KeychainStore.soniox.load() }).value else {
            sonioxCheck = .missing
            return
        }
        sonioxCheck = await KeyValidator.soniox(key)
    }

    private func verifyAnthropic() async {
        anthropicCheck = .checking
        guard let key = await Task.detached(operation: { KeychainStore.anthropic.load() }).value else {
            anthropicCheck = .missing
            return
        }
        anthropicCheck = await KeyValidator.anthropic(key)
    }
}
