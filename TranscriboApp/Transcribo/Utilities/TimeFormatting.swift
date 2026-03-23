import Foundation

enum TimeFormatting {
    /// Format seconds as HH:MM:SS
    static func timestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Format seconds as SRT timestamp: HH:MM:SS,mmm
    static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let totalSeconds = seconds
        let hours = Int(totalSeconds / 3600)
        let minutes = Int(totalSeconds.truncatingRemainder(dividingBy: 3600) / 60)
        let secs = Int(totalSeconds.truncatingRemainder(dividingBy: 60))
        let millis = Int((totalSeconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    /// Format duration for display (e.g., "1h 7m" or "3m 45s")
    static func durationDisplay(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        } else {
            return "\(secs)s"
        }
    }
}
