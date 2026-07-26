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

    /// Kill any active VibeVoice sidecar before the app exits. Without this,
    /// the Python child gets reparented to launchd and keeps the 5 GB MLX
    /// model resident — that's the orphan path that contributed to the
    /// April 28 thermal-shutdown chain. Runs synchronously so the AppKit
    /// shutdown sequence waits for our cleanup to finish.
    func applicationWillTerminate(_ notification: Notification) {
        VibeVoiceTranscriptionService.terminateAllActiveSidecars()
    }
}

/// The SwiftUI scene graph. Lives in the library (not the executable) so the
/// executable target is a three-line launcher and the headless CLI target can
/// link the same core without ever instantiating AppKit. See 10-consensus-spec.md.
public struct ConsensusApp: App {
    public init() {
        // Register the bundled OFL typefaces (Inter, Source Serif 4,
        // JetBrains Mono) before any view can resolve a `Font.custom`.
        // Safe for non-GUI launch modes (smoke harnesses) — does no drawing.
        FontRegistration.registerBundledFonts()
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel = TranscriptionViewModel()
    @StateObject private var settings = AppSettings()

    public var body: some Scene {
        WindowGroup {
            Group {
                if case .none = SmokeRunner.launchMode {
                ContentView()
                    .environment(viewModel)
                    .environmentObject(settings)
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
                        NotificationCenter.default.post(name: .consensusOpenAudioFile, object: nil)
                    }
                    .keyboardShortcut("o")
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
                }
            }
        }

        Settings {
            Group {
                if case .none = SmokeRunner.launchMode {
                    SettingsView()
                        .environment(viewModel)
                        .environmentObject(settings)
                } else {
                    EmptyView()
                }
            }
        }
    }
}
