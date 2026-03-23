import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings()

    var body: some View {
        Form {
            Section("Transcription Defaults") {
                Picker("Preferred Model", selection: $settings.preferredModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text("\(model.displayName) (\(model.approximateSize))")
                            .tag(model.rawValue)
                    }
                }

                Stepper("Default Min Speakers: \(settings.defaultMinSpeakers)",
                        value: $settings.defaultMinSpeakers, in: 0...20)

                Stepper("Default Max Speakers: \(settings.defaultMaxSpeakers)",
                        value: $settings.defaultMaxSpeakers, in: 0...20)
            }

            Section("About") {
                LabeledContent("App", value: "Consensus")
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Engine", value: "WhisperKit (CoreML)")
                Text("All processing happens locally on your Mac. No data leaves your machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 320)
    }
}
