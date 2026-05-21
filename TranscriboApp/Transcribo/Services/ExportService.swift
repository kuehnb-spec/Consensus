import AppKit
import Foundation
import ZIPFoundation

enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case txt, md, obsidianMarkdown, json, srt, rtf, docx, legalPDF

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: return "Text"
        case .md: return "Markdown"
        case .obsidianMarkdown: return "Obsidian Markdown"
        case .json: return "JSON"
        case .srt: return "SRT Subtitles"
        case .rtf: return "Rich Text"
        case .docx: return "Word Document"
        case .legalPDF: return "Legal Transcript"
        }
    }

    var fileExtension: String {
        switch self {
        case .legalPDF: return "pdf"
        case .obsidianMarkdown: return "md"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .txt: return "doc.text"
        case .md: return "text.badge.checkmark"
        case .obsidianMarkdown: return "note.text"
        case .json: return "curlybraces"
        case .srt: return "captions.bubble"
        case .rtf: return "doc.richtext"
        case .docx: return "doc.fill"
        case .legalPDF: return "doc.text.magnifyingglass"
        }
    }
}

/// Options for legal transcript PDF generation.
struct LegalPDFOptions {
    var showElapsedTime: Bool = true
    var showClockTime: Bool = false
    var recordingStartTime: Date?
    var headerText: String = "TRANSCRIPT"

    // Cover page options
    var includeCoverPage: Bool = false
    var coverPageSummary: String?
    var coverPageActionItems: String?
    var audioFileName: String?
    var audioDuration: TimeInterval?
    var speakerNames: [String] = []
}

/// Generates export files in all supported formats.
/// Ported from Python transcribe.py format functions.
enum ExportService {

    // MARK: - Public API

    /// Export a single format to a URL.
    static func export(
        format: ExportFormat,
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping,
        legalPDFOptions: LegalPDFOptions = LegalPDFOptions(),
        to url: URL
    ) throws {
        let data: Data
        switch format {
        case .txt: data = Data(formatText(result: result, speakerMapping: speakerMapping).utf8)
        case .md: data = Data(formatMarkdown(result: result, speakerMapping: speakerMapping).utf8)
        case .obsidianMarkdown: data = Data(formatObsidianMarkdown(result: result, speakerMapping: speakerMapping).utf8)
        case .json: data = try formatJSON(result: result)
        case .srt: data = Data(formatSRT(result: result, speakerMapping: speakerMapping).utf8)
        case .rtf: data = Data(formatRTF(result: result, speakerMapping: speakerMapping).utf8)
        case .docx: data = try buildDOCX(result: result, speakerMapping: speakerMapping)
        case .legalPDF: data = try buildLegalPDF(result: result, speakerMapping: speakerMapping, options: legalPDFOptions)
        }
        try data.write(to: url)
    }

    /// Export selected formats to a directory. Returns dict of format -> file URL.
    static func exportAll(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping,
        formats: Set<ExportFormat>,
        legalPDFOptions: LegalPDFOptions = LegalPDFOptions(),
        to directory: URL
    ) throws -> [ExportFormat: URL] {
        var paths: [ExportFormat: URL] = [:]
        let baseName = result.audioFileName

        for format in formats {
            let fileName = "\(baseName)_transcript.\(format.fileExtension)"
            let fileURL = directory.appendingPathComponent(fileName)
            try export(format: format, result: result, speakerMapping: speakerMapping, legalPDFOptions: legalPDFOptions, to: fileURL)
            paths[format] = fileURL
        }

        return paths
    }

    // MARK: - Format: Plain Text
    // Port of format_transcript_text() from transcribe.py

    static func formatText(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping,
        includeTimestamps: Bool = true,
        highlightLowConfidence: Bool = false,
        qualityTierBadge: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("TRANSCRIPT: \(result.audioPath)")
        lines.append("Duration: \(TimeFormatting.timestamp(result.duration))")
        if let badge = qualityTierBadge {
            lines.append("Quality: \(badge)")
        }
        lines.append(String(repeating: "=", count: 60))
        lines.append("")

        var currentSpeaker: String?

        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            var text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            // Optionally mark low-confidence words with brackets
            if highlightLowConfidence, let words = seg.words {
                text = words.map { word in
                    if word.probability < 0.5 {
                        return "[\(word.word)]"
                    }
                    return word.word
                }.joined(separator: " ")
            }

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                lines.append("")
                if includeTimestamps {
                    let start = TimeFormatting.timestamp(seg.start)
                    let end = TimeFormatting.timestamp(seg.end)
                    lines.append("[\(start) - \(end)] \(speaker):")
                } else {
                    lines.append("\(speaker):")
                }
                lines.append("  \(text)")
            } else {
                lines.append("  \(text)")
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Format: Markdown
    // Port of format_transcript_markdown() from transcribe.py

    static func formatMarkdown(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        var lines: [String] = []

        // Header
        lines.append("# Transcript: \(result.audioFileName)")
        lines.append("")
        lines.append("**Duration:** \(TimeFormatting.timestamp(result.duration))")

        // Speaker legend
        let speakers = result.detectedSpeakers
        if !speakers.isEmpty {
            let names = speakers.map { speakerMapping.displayName(for: $0) }
            lines.append("**Speakers:** \(names.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        // Body
        var currentSpeaker: String?
        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                lines.append("")
                lines.append("**\(speaker)** `\(TimeFormatting.timestamp(seg.start))`")
                lines.append("")
                lines.append(text)
            } else {
                lines.append(text)
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatObsidianMarkdown(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        let speakers = result.detectedSpeakers.map { speakerMapping.displayName(for: $0) }
        let speakerList = speakers
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ", ")
        var lines: [String] = []
        lines.append("---")
        lines.append("title: \"\(result.audioFileName.replacingOccurrences(of: "\"", with: "\\\""))\"")
        lines.append("duration: \"\(TimeFormatting.timestamp(result.duration))\"")
        lines.append("speakers: [\(speakerList)]")
        lines.append("tags: [consensus/transcript]")
        lines.append("---")
        lines.append("")
        lines.append(formatMarkdown(result: result, speakerMapping: speakerMapping))
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Format: JSON

    static func formatJSON(result: TranscriptionResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(result)
    }

    // MARK: - Format: SRT
    // Port of format_transcript_srt() from transcribe.py

    static func formatSRT(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        var lines: [String] = []
        var index = 1

        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let startTS = TimeFormatting.srtTimestamp(seg.start)
            let endTS = TimeFormatting.srtTimestamp(seg.end)

            lines.append("\(index)")
            lines.append("\(startTS) --> \(endTS)")
            lines.append("[\(speaker)] \(text)")
            lines.append("")

            index += 1
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Format: RTF
    // Port of format_transcript_rtf() from transcribe.py

    static func formatRTF(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        var parts: [String] = []

        parts.append(#"{\rtf1\ansi\deff0"#)
        parts.append(#"{\fonttbl{\f0\fswiss Helvetica;}{\f1\fmodern Courier New;}}"#)
        parts.append(#"{\colortbl;\red0\green0\blue0;\red80\green80\blue80;}"#)
        parts.append(#"\f0\fs24"#)
        parts.append("")

        // Title
        let escapedName = rtfEscape(result.audioFileName)
        let duration = TimeFormatting.timestamp(result.duration)
        parts.append(#"{\b\fs32 Transcript: \#(escapedName)\b0\fs24\par}"#)
        parts.append("Duration: \(duration)\\par")
        parts.append(#"\line"#)

        var currentSpeaker: String?
        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                parts.append(#"\par"#)
                let ts = TimeFormatting.timestamp(seg.start)
                parts.append(
                    #"{\b \#(rtfEscape(speaker))\b0} {\f1\fs20\cf2 [\#(ts)]\f0\fs24\cf1}\par"#
                )
                parts.append("\(rtfEscape(text))\\par")
            } else {
                parts.append("\(rtfEscape(text))\\par")
            }
        }

        parts.append("}")
        return parts.joined(separator: "\n")
    }

    private static func rtfEscape(_ text: String) -> String {
        var result = ""
        for ch in text {
            switch ch {
            case "\\": result += "\\\\"
            case "{": result += "\\{"
            case "}": result += "\\}"
            default:
                if ch.asciiValue == nil || ch.asciiValue! > 127 {
                    result += "\\u\(ch.unicodeScalars.first!.value)?"
                } else {
                    result.append(ch)
                }
            }
        }
        return result
    }

    // MARK: - Format: DOCX (Open XML)
    // Port of save_transcript_docx() from transcribe.py

    static func buildDOCX(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) throws -> Data {
        let docXML = buildDocumentXML(result: result, speakerMapping: speakerMapping)
        let stylesXML = buildStylesXML()
        let contentTypesXML = buildContentTypesXML()
        let relsXML = buildRelsXML()
        let docRelsXML = buildDocumentRelsXML()

        // Build ZIP archive
        guard let archive = Archive(accessMode: .create) else {
            throw TranscriboError.exportFailed("Could not create DOCX archive.")
        }

        try archive.addEntry(
            with: "[Content_Types].xml",
            type: .file,
            uncompressedSize: Int64(contentTypesXML.utf8.count),
            provider: { position, size in Data(contentTypesXML.utf8) }
        )
        try archive.addEntry(
            with: "_rels/.rels",
            type: .file,
            uncompressedSize: Int64(relsXML.utf8.count),
            provider: { _, _ in Data(relsXML.utf8) }
        )
        try archive.addEntry(
            with: "word/document.xml",
            type: .file,
            uncompressedSize: Int64(docXML.utf8.count),
            provider: { _, _ in Data(docXML.utf8) }
        )
        try archive.addEntry(
            with: "word/styles.xml",
            type: .file,
            uncompressedSize: Int64(stylesXML.utf8.count),
            provider: { _, _ in Data(stylesXML.utf8) }
        )
        try archive.addEntry(
            with: "word/_rels/document.xml.rels",
            type: .file,
            uncompressedSize: Int64(docRelsXML.utf8.count),
            provider: { _, _ in Data(docRelsXML.utf8) }
        )

        return archive.data ?? Data()
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func buildDocumentXML(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping
    ) -> String {
        var body = ""

        // Title
        body += """
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
        <w:r><w:t>Transcript: \(xmlEscape(result.audioFileName))</w:t></w:r></w:p>
        """

        // Metadata
        let duration = TimeFormatting.timestamp(result.duration)
        let speakers = result.detectedSpeakers.map { speakerMapping.displayName(for: $0) }
        body += """
        <w:p>
        <w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Duration: \(duration)</w:t></w:r>
        <w:r><w:t xml:space="preserve">  |  Speakers: \(xmlEscape(speakers.joined(separator: ", ")))</w:t></w:r>
        </w:p>
        <w:p/>
        """

        // Segments
        var currentSpeaker: String?
        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                let ts = TimeFormatting.timestamp(seg.start)
                // Speaker heading with timestamp
                body += """
                <w:p><w:pPr><w:spacing w:before="200"/></w:pPr>
                <w:r><w:rPr><w:b/><w:sz w:val="22"/></w:rPr><w:t xml:space="preserve">\(xmlEscape(speaker))  </w:t></w:r>
                <w:r><w:rPr><w:sz w:val="18"/><w:color w:val="787878"/></w:rPr><w:t>[\(ts)]</w:t></w:r>
                </w:p>
                """
            }

            // Text paragraph
            body += """
            <w:p><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr>
            <w:r><w:t xml:space="preserve">\(xmlEscape(text))</w:t></w:r></w:p>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
                    xmlns:mo="http://schemas.microsoft.com/office/mac/office/2008/main"
                    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
                    xmlns:mv="urn:schemas-microsoft-com:mac:vml"
                    xmlns:o="urn:schemas-microsoft-com:office:office"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
                    xmlns:v="urn:schemas-microsoft-com:vml"
                    xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                    xmlns:w10="urn:schemas-microsoft-com:office:word"
                    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
                    xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
                    xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
                    xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
                    xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
                    mc:Ignorable="w14 wp14">
        <w:body>
        \(body)
        </w:body>
        </w:document>
        """
    }

    private static func buildStylesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
            <w:pPr><w:spacing w:after="120"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="32"/></w:rPr>
        </w:style>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:rPr><w:sz w:val="22"/><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/></w:rPr>
        </w:style>
        </w:styles>
        """
    }

    private static func buildContentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
    }

    private static func buildRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private static func buildDocumentRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
    }

    // MARK: - Format: Legal Transcript PDF
    // Standard court reporter format: 25 lines per page, line numbers, page numbers, Courier font

    static func buildLegalPDF(
        result: TranscriptionResult,
        speakerMapping: SpeakerMapping,
        options: LegalPDFOptions = LegalPDFOptions()
    ) throws -> Data {
        // Page geometry (US Letter: 612 x 792 points)
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let topMargin: CGFloat = 72      // 1 inch
        let bottomMargin: CGFloat = 72
        let leftMargin: CGFloat = 108    // 1.5 inch (room for line numbers + binding)
        let rightMargin: CGFloat = 72
        let lineNumberX: CGFloat = 72    // Where line numbers sit
        let linesPerPage = 25
        let lineSpacing: CGFloat = (pageHeight - topMargin - bottomMargin) / CGFloat(linesPerPage)
        let textWidth = pageWidth - leftMargin - rightMargin

        // Fonts
        let bodyFont = NSFont(name: "Courier", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont(name: "Courier-Bold", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let headerFont = NSFont(name: "Courier", size: 10)
            ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let lineNumFont = NSFont(name: "Courier", size: 10)
            ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
        ]
        let boldAttributes: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: NSColor.black,
        ]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.darkGray,
        ]
        let lineNumAttributes: [NSAttributedString.Key: Any] = [
            .font: lineNumFont,
            .foregroundColor: NSColor.gray,
        ]

        // Clock time formatter
        let clockFormatter = DateFormatter()
        clockFormatter.dateFormat = "h:mm:ss a"

        // ---- Prepare transcript lines ----
        // Each "line" is either a speaker header or a text line, word-wrapped to fit.
        struct TranscriptLine {
            let text: String
            let isSpeakerHeader: Bool
            let timestamp: String?  // Combined elapsed + clock time string for this line
        }

        /// Build a timestamp string for a segment based on options.
        func formatTimestamp(segStart: TimeInterval) -> String? {
            var parts: [String] = []
            if options.showElapsedTime {
                parts.append(TimeFormatting.timestamp(segStart))
            }
            if options.showClockTime, let startTime = options.recordingStartTime {
                let clockTime = startTime.addingTimeInterval(segStart)
                parts.append(clockFormatter.string(from: clockTime))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " | ")
        }

        var allLines: [TranscriptLine] = []

        // Header lines from user-editable header text
        let headerLines = options.headerText.components(separatedBy: "\n")
        for headerLine in headerLines {
            allLines.append(TranscriptLine(text: headerLine, isSpeakerHeader: false, timestamp: nil))
        }
        // Duration line
        allLines.append(TranscriptLine(
            text: "Duration: \(TimeFormatting.timestamp(result.duration))",
            isSpeakerHeader: false, timestamp: nil
        ))
        allLines.append(TranscriptLine(text: "", isSpeakerHeader: false, timestamp: nil))

        // Calculate max characters per line with Courier 12pt
        // Courier at 12pt is ~7.2 pts per character
        let charWidth: CGFloat = 7.2
        let maxCharsPerLine = Int(textWidth / charWidth)

        // Group segments by speaker runs, accumulating all text for the same speaker
        // into one block before word-wrapping. This prevents mid-sentence line breaks
        // caused by segment boundaries.
        struct SpeakerBlock {
            let speaker: String
            let firstSegStart: TimeInterval
            var accumulatedText: String
        }

        var speakerBlocks: [SpeakerBlock] = []
        var currentSpeaker: String?

        for seg in result.segments {
            let speaker = speakerMapping.displayName(for: seg.speakerID)
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            if speaker == currentSpeaker, !speakerBlocks.isEmpty {
                // Same speaker — append text to current block
                speakerBlocks[speakerBlocks.count - 1].accumulatedText += " " + text
            } else {
                // New speaker — start a new block
                currentSpeaker = speaker
                speakerBlocks.append(SpeakerBlock(
                    speaker: speaker,
                    firstSegStart: seg.start,
                    accumulatedText: text
                ))
            }
        }

        for block in speakerBlocks {
            if !allLines.isEmpty && allLines.last?.text != "" {
                allLines.append(TranscriptLine(text: "", isSpeakerHeader: false, timestamp: nil))
            }
            let ts = formatTimestamp(segStart: block.firstSegStart)
            let tsDisplay = ts.map { " [\($0)]" } ?? ""
            let header = "\(block.speaker.uppercased())\(tsDisplay):"
            allLines.append(TranscriptLine(text: header, isSpeakerHeader: true, timestamp: nil))

            // Word-wrap the full accumulated text as one block
            let wrappedLines = wordWrap(block.accumulatedText, maxWidth: maxCharsPerLine)
            for line in wrappedLines {
                allLines.append(TranscriptLine(text: line, isSpeakerHeader: false, timestamp: nil))
            }
        }

        // ---- Render PDF ----
        let totalPages = max(1, (allLines.count + linesPerPage - 1) / linesPerPage)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw TranscriboError.exportFailed("Could not create PDF context.")
        }

        // ---- Cover Page (optional) ----
        if options.includeCoverPage {
            pdfContext.beginPDFPage(nil)
            let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.current = nsContext

            let titleFont = NSFont(name: "Courier-Bold", size: 16) ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
            let sectionFont = NSFont(name: "Courier-Bold", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            let coverBody = bodyFont
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.black]
            let sectionAttrs: [NSAttributedString.Key: Any] = [.font: sectionFont, .foregroundColor: NSColor.black]
            let coverBodyAttrs: [NSAttributedString.Key: Any] = [.font: coverBody, .foregroundColor: NSColor.black]

            var coverY = pageHeight - topMargin

            // Title
            NSAttributedString(string: "TRANSCRIPT COVER PAGE", attributes: titleAttrs)
                .draw(at: NSPoint(x: leftMargin, y: coverY))
            coverY -= 24

            // Separator
            pdfContext.setStrokeColor(NSColor.black.cgColor)
            pdfContext.setLineWidth(1.0)
            pdfContext.move(to: CGPoint(x: leftMargin, y: coverY))
            pdfContext.addLine(to: CGPoint(x: pageWidth - rightMargin, y: coverY))
            pdfContext.strokePath()
            coverY -= 24

            // Metadata fields
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            dateFormatter.timeStyle = .short

            var metadataLines: [(String, String)] = []
            if let fileName = options.audioFileName {
                metadataLines.append(("File:", fileName))
            }
            if let startTime = options.recordingStartTime {
                metadataLines.append(("Recorded:", dateFormatter.string(from: startTime)))
            }
            if let duration = options.audioDuration {
                metadataLines.append(("Duration:", TimeFormatting.durationDisplay(duration)))
            }
            if !options.speakerNames.isEmpty {
                metadataLines.append(("Speakers:", options.speakerNames.joined(separator: ", ")))
            }

            for (label, value) in metadataLines {
                NSAttributedString(string: "\(label)  \(value)", attributes: coverBodyAttrs)
                    .draw(at: NSPoint(x: leftMargin, y: coverY))
                coverY -= lineSpacing
            }

            coverY -= lineSpacing

            // Summary section
            if let summary = options.coverPageSummary, !summary.isEmpty {
                NSAttributedString(string: "SUMMARY", attributes: sectionAttrs)
                    .draw(at: NSPoint(x: leftMargin, y: coverY))
                coverY -= lineSpacing

                let summaryLines = wordWrap(summary, maxWidth: maxCharsPerLine)
                for line in summaryLines {
                    guard coverY > bottomMargin else { break }
                    NSAttributedString(string: line, attributes: coverBodyAttrs)
                        .draw(at: NSPoint(x: leftMargin, y: coverY))
                    coverY -= lineSpacing
                }
                coverY -= lineSpacing / 2
            }

            // Action items section
            if let items = options.coverPageActionItems, !items.isEmpty,
               coverY > bottomMargin + lineSpacing * 2 {
                NSAttributedString(string: "ACTION ITEMS", attributes: sectionAttrs)
                    .draw(at: NSPoint(x: leftMargin, y: coverY))
                coverY -= lineSpacing

                let itemLines = wordWrap(items, maxWidth: maxCharsPerLine)
                for line in itemLines {
                    guard coverY > bottomMargin else { break }
                    NSAttributedString(string: line, attributes: coverBodyAttrs)
                        .draw(at: NSPoint(x: leftMargin, y: coverY))
                    coverY -= lineSpacing
                }
            }

            pdfContext.endPDFPage()
        }

        // ---- Transcript Pages ----
        for pageIndex in 0..<totalPages {
            pdfContext.beginPDFPage(nil)
            let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: false)
            NSGraphicsContext.current = nsContext

            // Page header (offset page numbers if cover page exists)
            let displayPage = options.includeCoverPage ? pageIndex + 2 : pageIndex + 1
            let displayTotal = options.includeCoverPage ? totalPages + 1 : totalPages
            let pageHeaderText = "\(result.audioFileName)    Page \(displayPage) of \(displayTotal)"
            let headerStr = NSAttributedString(string: pageHeaderText, attributes: headerAttributes)
            headerStr.draw(at: NSPoint(x: leftMargin, y: pageHeight - 50))

            // Header separator line
            pdfContext.setStrokeColor(NSColor.gray.cgColor)
            pdfContext.setLineWidth(0.5)
            pdfContext.move(to: CGPoint(x: lineNumberX, y: pageHeight - 56))
            pdfContext.addLine(to: CGPoint(x: pageWidth - rightMargin, y: pageHeight - 56))
            pdfContext.strokePath()

            // Footer separator line
            pdfContext.move(to: CGPoint(x: lineNumberX, y: bottomMargin - 10))
            pdfContext.addLine(to: CGPoint(x: pageWidth - rightMargin, y: bottomMargin - 10))
            pdfContext.strokePath()

            // Draw lines
            let startLineIndex = pageIndex * linesPerPage
            for lineOnPage in 0..<linesPerPage {
                let globalLine = startLineIndex + lineOnPage
                guard globalLine < allLines.count else { break }

                let transcriptLine = allLines[globalLine]
                // Y position (PDF origin is bottom-left, we draw from top)
                let y = pageHeight - topMargin - CGFloat(lineOnPage) * lineSpacing - lineSpacing

                // Line number (1-25 per page)
                let lineNumStr = NSAttributedString(
                    string: String(format: "%2d", lineOnPage + 1),
                    attributes: lineNumAttributes
                )
                lineNumStr.draw(at: NSPoint(x: lineNumberX, y: y))

                // Text
                let attrs = transcriptLine.isSpeakerHeader ? boldAttributes : bodyAttributes
                let textStr = NSAttributedString(string: transcriptLine.text, attributes: attrs)
                textStr.draw(at: NSPoint(x: leftMargin, y: y))
            }

            pdfContext.endPDFPage()
        }

        NSGraphicsContext.current = nil
        pdfContext.closePDF()

        return pdfData as Data
    }

    /// Simple word-wrap for monospaced text.
    private static func wordWrap(_ text: String, maxWidth: Int) -> [String] {
        guard maxWidth > 0 else { return [text] }
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var currentLine = ""

        for word in words {
            if currentLine.isEmpty {
                currentLine = word
            } else if currentLine.count + 1 + word.count <= maxWidth {
                currentLine += " " + word
            } else {
                lines.append(currentLine)
                currentLine = word
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        return lines.isEmpty ? [""] : lines
    }
}
