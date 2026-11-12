import AppKit
import Sparkle
import SwiftUI

@main
struct KanpeApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Kanpe", id: "main") {
            SubtitleView()
                .environmentObject(appDelegate.session)
                // 最小幅は SubtitleView が決める。
                .frame(minHeight: 240)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 560, height: 400)
        .windowToolbarStyle(.unified)
        .commands {
            UpdateCommands(updater: appDelegate.updater.updater)
            MeetingCommands(session: appDelegate.session)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.session)
                .preferredColorScheme(.light)
        }
    }
}

/// 終了時に録音を閉じる。⌘Q でも `kill`（SIGTERM）でも、m4a の目次を書いてから終わる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = MeetingSession()
    /// Sparkle。起動時に自動確認を始める（SUFeedURL / SUPublicEDKey は Info.plist）。
    /// 「インストールして再起動」は普通の終了を通るので、録音中でも m4a は閉じられる。
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }
}
