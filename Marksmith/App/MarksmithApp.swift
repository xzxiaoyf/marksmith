import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MarksmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        ExportRegistry.shared.bootstrap()
        ImportRegistry.shared.bootstrap()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { MarksmithDocument() }) { file in
            // `file.fileURL` belongs to THIS window. Do not read
            // NSDocumentController.shared.currentDocument here: with several
            // windows it can point at another document, and on first appear it
            // may still be nil. Relative image paths, exports and the assets/
            // directory all derive their base directory from this value.
            ContentView(document: file.document, documentURL: file.fileURL)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
        }
    }
}
