import SwiftUI

/// 用語セットの選択肢。ツールバーのメニューとメニューバーの「会議」メニューで共有する。
struct ContextMenuItems: View {
    @EnvironmentObject private var session: MeetingSession

    var body: some View {
        Picker("用語セット", selection: $session.contextName) {
            Text("用語なし").tag(String?.none)
            ForEach(session.contextNames, id: \.self) { name in
                Text(name).tag(String?.some(name))
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("一覧を更新") { session.refreshContexts() }
        Button("用語フォルダを開く") { session.openContextsFolder() }
    }
}

/// HIG：ツールバーの操作はすべてメニューバーからも使えるようにする。
struct MeetingCommands: Commands {
    @ObservedObject var session: MeetingSession

    var body: some Commands {
        CommandMenu("会議") {
            Button(session.isRunning || session.isStarting ? "停止" : "開始") { session.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!session.canStart)
            Divider()
            Picker("会議の形式", selection: $session.mode) {
                ForEach(MeetingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .disabled(session.isRunning || session.isStarting)
            Menu("用語セット") {
                ContextMenuItems()
                    .environmentObject(session)
            }
            .disabled(session.isRunning || session.isStarting)
            Divider()
            Button("カンペに質問…") { session.askRequest += 1 }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!session.hasAnthropicKey)
            Toggle("質問に自動で答える", isOn: $session.autoAnswer)
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!session.hasAnthropicKey)
            Divider()
            Button("再文字起こし…") { session.chooseAndRetranscribe() }
                .disabled(session.isRunning || session.retranscribeStatus != nil || !session.hasKey)
            Button("保存フォルダを開く") { session.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(session.folder == nil)
        }
    }
}
