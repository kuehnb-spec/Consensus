import Foundation
import CoreText
import os

/// Registers the OFL-licensed typefaces shipped with the rewritten UI so that
/// SwiftUI's `Font.custom(_, size:)` can resolve them. Called once from
/// `ConsensusApp.init()` at launch.
///
/// The three families and their family names (as embedded in each font's
/// `name` table):
/// - **Inter** → `Font.custom("Inter", size:)`
/// - **Source Serif 4** → `Font.custom("Source Serif 4", size:)`
/// - **JetBrains Mono** → `Font.custom("JetBrains Mono", size:)`
///
/// All three are variable fonts (weight axis at minimum), so SwiftUI's
/// `.fontWeight(_:)` modifier works against them without needing a static
/// file per weight.
enum FontRegistration {
    private static let log = Logger(subsystem: "com.bdk.consensus", category: "fonts")

    /// Font file resources we ship. Kept explicit so a missing file surfaces
    /// as a visible warning instead of silently falling back to the system
    /// font.
    static let bundledFontResources: [(directory: String, filename: String)] = [
        ("Inter",         "Inter-VF.ttf"),
        ("Inter",         "Inter-Italic-VF.ttf"),
        ("SourceSerif4",  "SourceSerif4-VF.ttf"),
        ("SourceSerif4",  "SourceSerif4-Italic-VF.ttf"),
        ("JetBrainsMono", "JetBrainsMono-VF.ttf"),
        ("JetBrainsMono", "JetBrainsMono-Italic-VF.ttf"),
    ]

    /// Idempotent. Safe to call more than once; CoreText treats a re-register
    /// of the same URL as a no-op and returns `.alreadyRegistered`.
    static func registerBundledFonts() {
        for (directory, filename) in bundledFontResources {
            register(directory: directory, filename: filename)
        }
    }

    /// The SwiftPM resource bundle, resolved without trapping.
    ///
    /// `Bundle.module` calls `fatalError` when it cannot locate its bundle,
    /// which crashes the app during `ConsensusApp.init()` — before any window
    /// exists, so the user sees only a crash report. That happened in the
    /// 1.1 build: the target was renamed (`Consensus` → `ConsensusCore`), so
    /// the expected bundle name changed while a stale bundle was shipped.
    /// Typefaces are cosmetic; a missing bundle must degrade to system fonts,
    /// never take the process down.
    private static let resourceBundle: Bundle? = {
        // Current and historical bundle names, so an older layout still works.
        let names = ["Consensus_ConsensusCore", "Consensus_Consensus"]
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        // Next to the executable — how SwiftPM lays things out for a bare binary.
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executable)
        }

        for root in roots {
            for name in names {
                let candidate = root.appendingPathComponent("\(name).bundle")
                if let bundle = Bundle(url: candidate) { return bundle }
            }
        }
        // Resources may also be flattened directly into the app bundle.
        return Bundle.main
    }()

    private static func register(directory: String, filename: String) {
        let subdir = "App/Resources/Fonts/\(directory)"
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        guard let bundle = resourceBundle,
              let url = bundle.url(
                forResource: stem,
                withExtension: ext,
                subdirectory: subdir
              ) ?? bundle.url(
                forResource: stem,
                withExtension: ext,
                subdirectory: directory
              ) else {
            log.error("Font resource not found in bundle: \(subdir)/\(filename, privacy: .public)")
            return
        }

        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let cfError = error?.takeRetainedValue() {
            let nsError = cfError as Error as NSError
            // `.alreadyRegistered` is harmless — the registration scope is the
            // process and we're called once per launch, but guard anyway for
            // hot-reload scenarios.
            if nsError.domain == kCTFontManagerErrorDomain as String,
               nsError.code == CTFontManagerError.alreadyRegistered.rawValue {
                return
            }
            log.error("Failed to register \(filename, privacy: .public): \(nsError.localizedDescription, privacy: .public)")
        }
    }
}
