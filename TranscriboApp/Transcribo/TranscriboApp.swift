import SwiftUI
import AppKit

/// Ensures the SPM executable gets full macOS app behavior:
/// keyboard events, menu bar, Dock icon, proper window activation.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard case .none = SmokeRunner.launchMode else {
            Task { @MainActor in
                await SmokeRunner.runFromLaunchMode()
            }
            return
        }

        // Make this a regular foreground app (not background/accessory)
        NSApp.setActivationPolicy(.regular)
        // Force activate so the window becomes key and accepts keyboard input
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard case .none = SmokeRunner.launchMode else { return }
        // Ensure the main window is key whenever the app activates
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct ConsensusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = TranscriptionViewModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if case .none = SmokeRunner.launchMode {
                ContentView()
                    .environment(viewModel)
                    .frame(minWidth: 900, minHeight: 600)
                    .preferredColorScheme(.dark)
                    .tint(ConsensusTheme.Colors.accent)
                } else {
                    EmptyView()
                        .frame(width: 1, height: 1)
                    }
                }
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Standard Edit menu — required for TextField keyboard input on macOS
            TextEditingCommands()
            TextFormattingCommands()

            CommandGroup(replacing: .newItem) {
                if case .none = SmokeRunner.launchMode {
                    Button("Open Audio File...") {
                        viewModel.showFilePicker = true
                    }
                    .keyboardShortcut("o")

                    Button("Open Demo Project") {
                        Task {
                            await viewModel.loadDemoProject()
                        }
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }
            }

            CommandMenu("Guided Help") {
                if case .none = SmokeRunner.launchMode {
                    Button("Help Center") {
                        viewModel.openHelpCenter()
                    }
                    .keyboardShortcut("/", modifiers: [.command, .shift])

                    Button("Welcome Tour") {
                        viewModel.presentWelcomeTour()
                    }

                    Divider()

                    Button("Open Demo Project") {
                        Task {
                            await viewModel.loadDemoProject()
                        }
                    }
                }
            }
        }

        Settings {
            Group {
                if case .none = SmokeRunner.launchMode {
                    SettingsView()
                        .environment(viewModel)
                } else {
                    EmptyView()
                }
            }
        }
    }
}
