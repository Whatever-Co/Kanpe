import Combine
import Sparkle
import SwiftUI

/// Sparkle の「アップデートを確認…」。アプリメニューの「Kanpe について」の下に置く。
/// 確認中は押せないようにする（Sparkle の SwiftUI サンプルと同じ形）。
struct UpdateCommands: Commands {
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }
}

private struct CheckForUpdatesButton: View {
    @StateObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: CheckForUpdatesModel(updater: updater))
    }

    var body: some View {
        Button("アップデートを確認…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

@MainActor
private final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
