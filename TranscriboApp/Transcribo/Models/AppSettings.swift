import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("preferredModel") var preferredModel: String = WhisperModel.small.rawValue
    @AppStorage("defaultMinSpeakers") var defaultMinSpeakers: Int = 2
    @AppStorage("defaultMaxSpeakers") var defaultMaxSpeakers: Int = 6
    @AppStorage("defaultLanguage") var defaultLanguage: String = "en"
    @AppStorage("hasSeenWelcomeTour") var hasSeenWelcomeTour: Bool = false

    var preferredWhisperModel: WhisperModel {
        get { WhisperModel(rawValue: preferredModel) ?? .small }
        set { preferredModel = newValue.rawValue }
    }
}
