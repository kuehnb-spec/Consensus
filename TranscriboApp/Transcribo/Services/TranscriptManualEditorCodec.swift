import Foundation

/// Serializer and parser for the Manual Editor text format.
///
/// The editor represents a transcript as a human-readable flow of turns, each
/// introduced by a speaker header:
///
///     [BRANT @ 00:00:00]
///     Um, and then, so she's been really with me on this.
///
///     [MARIE @ 00:00:34]
///     Or something like that. Let's do this.
///
/// The format is deliberately identical to the proposed ground-truth file format
/// so a user can open an auto-generated transcript in the editor, manually perfect
/// it while listening to the audio, and save a file that doubles as both the final
/// corrected transcript AND the gold standard for benchmarking.
enum TranscriptManualEditorCodec {

    // MARK: - Serialize

    /// Render a list of segments as the editor's text format.
    ///
    /// - Parameter segments: the current pass's segments, in time order.
    /// - Parameter mapping: maps `SPEAKER_N` → display name (e.g. "Brant"). If a
    ///     segment's speaker has no mapping entry, the raw `SPEAKER_N` is used.
    /// - Returns: a single string suitable for dropping into a `TextEditor`.
    static func serialize(
        segments: [TranscriptionSegment],
        mapping: SpeakerMapping
    ) -> String {
        var lines: [String] = []
        var previousSpeaker: String? = nil

        for segment in segments {
            let speakerDisplay = mapping.displayName(for: segment.speakerID).uppercased()
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // If this is a new speaker turn, emit a header. Otherwise collapse into
            // the previous turn with a space join — keeps the editor readable instead
            // of producing a header for every 2-second segment.
            if speakerDisplay != previousSpeaker {
                if !lines.isEmpty { lines.append("") }
                lines.append("[\(speakerDisplay) @ \(formatTimestamp(segment.start))]")
                lines.append(text)
            } else {
                if var last = lines.last, !last.isEmpty {
                    last += " " + text
                    lines[lines.count - 1] = last
                } else {
                    lines.append(text)
                }
            }
            previousSpeaker = speakerDisplay
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    struct ParsedTurn: Sendable {
        let speakerDisplay: String     // "BRANT" (uppercase)
        let timestamp: TimeInterval    // seconds from start of audio
        let text: String               // joined paragraphs, trimmed
        let timestampWasExplicit: Bool // false when the time was interpolated
    }

    /// Header regex: `[NAME @ HH:MM:SS]` or `[NAME @ MM:SS]`. The `@ TIME` portion is
    /// optional — a bare `[NAME]` on its own line is also treated as a turn break, in
    /// which case the time is interpolated from surrounding headers on parse.
    private static let headerRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\s*\[(?<speaker>[^\]@]+?)(?:\s*@\s*(?<time>\d{1,2}:\d{2}(?::\d{2})?))?\s*\]\s*$"#,
        options: []
    )

    /// Parse editor text back into turns. Accepts `[NAME @ HH:MM:SS]`, `[NAME @ MM:SS]`,
    /// or bare `[NAME]` headers. Missing timestamps are interpolated post-parse from
    /// the nearest timestamped neighbors, weighted by word count in between so the
    /// interpolation tracks the natural pacing of the conversation.
    static func parse(_ text: String) -> [ParsedTurn] {
        // First pass: collect turns with possibly-nil timestamps.
        var partial: [(speaker: String, time: TimeInterval?, text: String)] = []
        var currentSpeaker: String? = nil
        var currentTime: TimeInterval? = nil
        var currentHasExplicitTime: Bool = false
        var currentText: [String] = []

        func flushPartial() {
            guard let speaker = currentSpeaker else {
                currentText = []
                return
            }
            let joined = currentText
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                partial.append((speaker.uppercased(), currentTime, joined))
            }
            currentText = []
            currentHasExplicitTime = false
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let header = parseHeader(line) {
                flushPartial()
                currentSpeaker = header.speaker
                currentTime = header.time
                currentHasExplicitTime = header.time != nil
            } else {
                currentText.append(line)
            }
        }
        flushPartial()

        // Second pass: interpolate missing timestamps.
        // For each run of consecutive turns with nil timestamps, interpolate between
        // the last explicit time before the run and the first explicit time after,
        // proportional to word counts so longer turns absorb more of the interval.
        let wordCounts: [Int] = partial.map {
            $0.text.split(whereSeparator: { $0.isWhitespace }).count
        }

        var anchorTimes: [TimeInterval?] = partial.map { $0.time }

        // Back-fill leading nils if the first turn has no timestamp: estimate each
        // preceding turn at ~0.35s per word before the first explicit anchor.
        if !anchorTimes.isEmpty, anchorTimes[0] == nil,
           let firstExplicitIdx = anchorTimes.firstIndex(where: { $0 != nil }),
           let firstTime = anchorTimes[firstExplicitIdx] {
            var cursor = firstTime
            for i in stride(from: firstExplicitIdx - 1, through: 0, by: -1) {
                cursor = max(0, cursor - Double(max(1, wordCounts[i])) * 0.35)
                anchorTimes[i] = cursor
            }
        }

        // Fill nil gaps between explicit anchors with word-weighted interpolation.
        var lastAnchor: Int? = nil
        for i in 0..<anchorTimes.count {
            guard anchorTimes[i] != nil else { continue }
            if let prev = lastAnchor, prev < i - 1 {
                let startTime = anchorTimes[prev]!
                let endTime = anchorTimes[i]!
                let gap = endTime - startTime
                let totalWordsInGap = (prev + 1..<i).reduce(0) { $0 + wordCounts[$1] }
                for j in (prev + 1)..<i {
                    let wordsBeforeJ = (prev + 1..<j).reduce(0) { $0 + wordCounts[$1] }
                    let ratio = totalWordsInGap > 0
                        ? Double(wordsBeforeJ) / Double(totalWordsInGap)
                        : Double(j - prev - 1) / Double(i - prev - 1)
                    anchorTimes[j] = startTime + gap * ratio
                }
            }
            lastAnchor = i
        }

        // Extrapolate any trailing nils after the last explicit anchor.
        if let last = lastAnchor, last < anchorTimes.count - 1, let lastTime = anchorTimes[last] {
            var cursor = lastTime
            for i in (last + 1)..<anchorTimes.count {
                cursor += Double(max(1, wordCounts[i])) * 0.35
                anchorTimes[i] = cursor
            }
        }

        // Build final turns.
        var turns: [ParsedTurn] = []
        for (idx, p) in partial.enumerated() {
            let time = anchorTimes[idx] ?? p.time ?? 0
            turns.append(ParsedTurn(
                speakerDisplay: p.speaker,
                timestamp: max(0, time),
                text: p.text,
                timestampWasExplicit: p.time != nil
            ))
        }
        return turns
    }

    private static func parseHeader(_ line: String) -> (speaker: String, time: TimeInterval?)? {
        guard let regex = headerRegex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else {
            return nil
        }

        guard let speakerRange = Range(match.range(withName: "speaker"), in: line) else {
            return nil
        }
        let speaker = String(line[speakerRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        // The time group may be missing (bare [NAME] header).
        let nsTimeRange = match.range(withName: "time")
        if nsTimeRange.location == NSNotFound {
            return (speaker, nil)
        }
        guard let timeRange = Range(nsTimeRange, in: line) else {
            return (speaker, nil)
        }
        let timeText = String(line[timeRange])
        return (speaker, parseTimestamp(timeText))
    }

    // MARK: - Rebuild segments from parsed turns

    /// Rebuild `TranscriptionSegment`s from parsed editor turns. Preserves word
    /// timings from the original segments when the edited text contains the same
    /// words in the same order (best-effort matching by normalized word form).
    /// Falls back to linear interpolation across the turn when word matching fails.
    ///
    /// - Parameter turns: parsed editor output.
    /// - Parameter original: the segments that were shown in the editor before the
    ///     user made changes. Used to recover word-level timings.
    /// - Parameter mapping: the current speaker mapping — used to resolve display
    ///     names back to `SPEAKER_N` IDs. Unknown display names are preserved as-is
    ///     (treated as new logical speakers).
    /// - Parameter audioDuration: total audio duration, used to bound the final
    ///     turn's end time.
    static func rebuildSegments(
        from turns: [ParsedTurn],
        original: [TranscriptionSegment],
        mapping: SpeakerMapping,
        audioDuration: TimeInterval
    ) -> [TranscriptionSegment] {
        guard !turns.isEmpty else { return [] }

        // Reverse display-name lookup: display name (uppercase) → speakerID.
        var displayToID: [String: String] = [:]
        for (id, name) in mapping.names {
            displayToID[name.uppercased()] = id
        }

        // Flat list of original words with their speaker IDs, for best-effort
        // word-timing recovery.
        var originalWordIndex: Int = 0
        let originalWords: [(word: String, norm: String, timing: TranscriptionSegment.WordTiming, speakerID: String)]
            = original.flatMap { segment -> [(String, String, TranscriptionSegment.WordTiming, String)] in
                (segment.words ?? []).map { w in
                    (w.word, normalize(w.word), w, segment.speakerID)
                }
            }

        var result: [TranscriptionSegment] = []
        for (index, turn) in turns.enumerated() {
            let speakerID = displayToID[turn.speakerDisplay]
                ?? "MANUAL_\(turn.speakerDisplay)"

            // End time: start of next turn, or total audio duration for the last.
            let endTime: TimeInterval = (index + 1 < turns.count)
                ? turns[index + 1].timestamp
                : audioDuration

            // Pull words from the edited text in their edited order.
            let editedWords = turn.text
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }

            var recoveredTimings: [TranscriptionSegment.WordTiming] = []
            recoveredTimings.reserveCapacity(editedWords.count)

            for editedWord in editedWords {
                let editedNorm = normalize(editedWord)
                // Walk forward through original words looking for a match (case-
                // insensitive, punctuation-stripped). Skip up to a few non-matches
                // to tolerate minor ASR fixes inline.
                var matched = false
                let searchEnd = min(originalWordIndex + 6, originalWords.count)
                for probe in originalWordIndex..<searchEnd {
                    if originalWords[probe].norm == editedNorm
                       && !editedNorm.isEmpty {
                        recoveredTimings.append(TranscriptionSegment.WordTiming(
                            word: editedWord,
                            start: originalWords[probe].timing.start,
                            end: originalWords[probe].timing.end,
                            probability: originalWords[probe].timing.probability
                        ))
                        originalWordIndex = probe + 1
                        matched = true
                        break
                    }
                }
                if !matched {
                    // No match found nearby: leave timing blank, fill with linear
                    // interpolation after the whole turn is scanned.
                    recoveredTimings.append(TranscriptionSegment.WordTiming(
                        word: editedWord,
                        start: Float.nan,
                        end: Float.nan,
                        probability: 0.0
                    ))
                }
            }

            // Fill NaN timings with linear interpolation across the turn duration.
            let turnDuration = max(0.01, endTime - turn.timestamp)
            let perWord = Float(turnDuration / Double(max(1, editedWords.count)))
            for i in 0..<recoveredTimings.count {
                if recoveredTimings[i].start.isNaN {
                    let start = Float(turn.timestamp) + Float(i) * perWord
                    recoveredTimings[i] = TranscriptionSegment.WordTiming(
                        word: recoveredTimings[i].word,
                        start: start,
                        end: start + perWord,
                        probability: recoveredTimings[i].probability
                    )
                }
            }

            let text = editedWords.joined(separator: " ")
            result.append(TranscriptionSegment(
                speakerID: speakerID,
                start: turn.timestamp,
                end: endTime,
                text: text,
                words: recoveredTimings.isEmpty ? nil : recoveredTimings
            ))
        }

        return result
    }

    // MARK: - Cursor → Audio Time

    /// Given the editor text and a cursor character offset, return the approximate
    /// audio time at that cursor position. Used to drive the "Play Context" button.
    ///
    /// Algorithm: find the most recent `[SPEAKER @ TIME]` header at or before the
    /// cursor. Count words between that header and the cursor. Linearly interpolate
    /// against the NEXT header's timestamp (if any) to get a position within the turn.
    /// If no next header exists, interpolate against the end of the cursor's
    /// paragraph plus a small padding.
    ///
    /// - Parameter text: the full editor text.
    /// - Parameter cursorOffset: character offset into `text`.
    /// - Parameter fallbackDuration: returned when no valid header precedes the cursor.
    /// - Returns: an approximate audio time (seconds) that corresponds to the cursor.
    static func timeForCursor(
        in text: String,
        cursorOffset: Int,
        fallbackDuration: TimeInterval = 0
    ) -> TimeInterval {
        let clampedOffset = max(0, min(cursorOffset, text.count))
        let endIndex = text.index(text.startIndex, offsetBy: clampedOffset)
        let prefix = String(text[text.startIndex..<endIndex])

        let headers = locateHeaders(in: text)
        guard let lastBefore = headers.last(where: { $0.charIndex <= clampedOffset }) else {
            return fallbackDuration
        }

        let nextAfter = headers.first { $0.charIndex > clampedOffset }

        // Count words in [lastBefore.lineEnd ... cursor)
        let afterHeaderStart = text.index(text.startIndex, offsetBy: min(lastBefore.lineEnd, clampedOffset))
        let textBetween = String(text[afterHeaderStart..<endIndex])
        let wordsBetween = textBetween
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .count

        // Total words in the turn (either until next header, or until end of text).
        let turnEndCharIndex = nextAfter?.charIndex ?? text.count
        let turnStartCharIndex = min(lastBefore.lineEnd, turnEndCharIndex)
        let startIndex = text.index(text.startIndex, offsetBy: turnStartCharIndex)
        let stopIndex = text.index(text.startIndex, offsetBy: turnEndCharIndex)
        let turnText = String(text[startIndex..<stopIndex])
        let totalWordsInTurn = max(1, turnText
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .count)

        let nextTime = nextAfter?.time ?? max(lastBefore.time + 10, fallbackDuration)
        let turnDuration = max(0.5, nextTime - lastBefore.time)
        let ratio = Double(wordsBetween) / Double(totalWordsInTurn)
        return lastBefore.time + turnDuration * ratio
    }

    private struct HeaderLocation {
        let charIndex: Int   // character offset of the '[' of the header
        let lineEnd: Int     // character offset immediately after the header line's trailing newline
        let speaker: String
        let time: TimeInterval
    }

    private static func locateHeaders(in text: String) -> [HeaderLocation] {
        guard let regex = headerRegex else { return [] }
        var result: [HeaderLocation] = []
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil,
               let (speaker, maybeTime) = parseHeader(trimmed),
               let time = maybeTime {
                // Cursor-to-time mapping only uses explicitly-timestamped headers as
                // anchors; untimed `[NAME]` breaks don't have a reliable time to seek to.
                let charIndex = text.distance(from: text.startIndex, to: lineStart)
                let lineEndIndex = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                let afterIndex = text.distance(from: text.startIndex, to: lineEndIndex)
                result.append(HeaderLocation(
                    charIndex: charIndex,
                    lineEnd: afterIndex,
                    speaker: speaker,
                    time: time
                ))
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        return result
    }

    // MARK: - Helpers

    private static func normalize(_ word: String) -> String {
        word
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "00:%02d:%02d", m, s)
    }

    private static func parseTimestamp(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map(String.init)
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        switch nums.count {
        case 2:
            return TimeInterval(nums[0] * 60 + nums[1])
        case 3:
            return TimeInterval(nums[0] * 3600 + nums[1] * 60 + nums[2])
        default:
            return nil
        }
    }
}
