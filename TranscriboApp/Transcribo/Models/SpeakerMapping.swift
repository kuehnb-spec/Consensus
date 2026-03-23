import Foundation

struct SpeakerMapping: Codable, Sendable {
    var names: [String: String] = [:]

    func displayName(for speakerID: String) -> String {
        names[speakerID] ?? speakerID
    }

    mutating func rename(_ speakerID: String, to name: String) {
        if name.isEmpty || name == speakerID {
            names.removeValue(forKey: speakerID)
        } else {
            names[speakerID] = name
        }
    }

    var isEmpty: Bool { names.isEmpty }
}
