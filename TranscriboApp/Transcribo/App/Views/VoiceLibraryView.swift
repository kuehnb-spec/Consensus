import SwiftUI

/// Studio-only manager for the voice library. Shows every known voice with
/// rename / tag / delete actions, plus cross-references to the projects each
/// voice has appeared in.
///
/// Phase 4 ships the UI + manual-management paths. Phase 4.2 (SpeakerKit
/// embedding extraction + auto-match-on-transcription) will populate the
/// store automatically; until then this view is a manager UI for a library
/// that grows via manual add only. Shipped behind a clear empty-state copy.
struct VoiceLibraryView: View {
    @Bindable var viewModel: DeepReadViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedVoiceID: UUID?
    @State private var editingName: String = ""
    @State private var query: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)

            Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 520)
        .background(ConsensusTheme.Colors.background)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Library")
                        .font(ConsensusType.displayHeading)
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                    Text("\(viewModel.voiceStore.library.voices.count) voice\(viewModel.voiceStore.library.voices.count == 1 ? "" : "s")")
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(ConsensusTheme.Spacing.md)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ConsensusTheme.Colors.borderSubtle).frame(height: 1)
            }

            searchField
                .padding(.horizontal, ConsensusTheme.Spacing.md)
                .padding(.top, ConsensusTheme.Spacing.sm)

            if filteredVoices.isEmpty {
                emptySidebar
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredVoices) { voice in
                            voiceRow(voice: voice)
                        }
                    }
                    .padding(ConsensusTheme.Spacing.sm)
                }
            }
        }
        .background(ConsensusTheme.Colors.surfacePrimary.opacity(0.5))
    }

    private var searchField: some View {
        HStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            TextField("Search voices", text: $query)
                .textFieldStyle(.plain)
                .font(ConsensusType.displayCaption)
        }
        .padding(.horizontal, ConsensusTheme.Spacing.sm)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                .fill(ConsensusTheme.Colors.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                        .stroke(ConsensusTheme.Colors.borderSubtle, lineWidth: 1)
                )
        )
    }

    private func voiceRow(voice: VoiceIdentity) -> some View {
        let selected = voice.id == selectedVoiceID
        return Button {
            selectedVoiceID = voice.id
            editingName = voice.displayName
        } label: {
            HStack(spacing: ConsensusTheme.Spacing.sm) {
                VoiceAvatar(voice: voice)

                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.displayName)
                        .font(ConsensusType.displayBody.weight(.medium))
                        .foregroundStyle(ConsensusTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(Self.subtitle(for: voice))
                        .font(ConsensusType.displayCaption)
                        .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, ConsensusTheme.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ConsensusTheme.Radius.sm, style: .continuous)
                    .fill(selected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptySidebar: some View {
        VStack(spacing: ConsensusTheme.Spacing.sm) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
            Text("No voices yet")
                .font(ConsensusType.displaySubheading)
                .foregroundStyle(ConsensusTheme.Colors.textPrimary)
            Text("Voices are added automatically when SpeakerKit embeddings land. Phase 4.2.")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, ConsensusTheme.Spacing.md)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let voice = selectedVoice {
            ScrollView {
                VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.lg) {
                    detailHeader(voice: voice)
                    tagsSection(voice: voice)
                    appearancesSection(voice: voice)
                    dangerSection(voice: voice)
                }
                .padding(ConsensusTheme.Spacing.xl)
            }
        } else {
            VStack {
                Spacer()
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                Text("Pick a voice to edit")
                    .font(ConsensusType.displayBody)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func detailHeader(voice: VoiceIdentity) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("NAME")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)
            HStack {
                TextField("Voice name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .font(ConsensusType.displayBody)
                    .onSubmit {
                        rename(voice: voice, to: editingName)
                    }
                Button("Save") {
                    rename(voice: voice, to: editingName)
                }
                .buttonStyle(.bordered)
                .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines) == voice.displayName
                          || editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Created \(Self.format(voice.createdAt))  ·  Last seen \(Self.format(voice.lastSeenAt))")
                .font(ConsensusType.displayCaption)
                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
        }
    }

    private func tagsSection(voice: VoiceIdentity) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("TAGS")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)
            let builtins: [VoiceTag] = [
                .myVoice, .frequentCaller, .client, .colleague, .family
            ]
            WrapHStack {
                ForEach(builtins, id: \.self) { tag in
                    tagChip(tag: tag, voice: voice)
                }
            }
        }
    }

    private func tagChip(tag: VoiceTag, voice: VoiceIdentity) -> some View {
        let selected = voice.tags.contains(tag)
        return Button {
            toggle(tag: tag, on: voice)
        } label: {
            Text(tag.displayName)
                .font(ConsensusType.displayCaption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, ConsensusTheme.Spacing.sm)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? ConsensusTheme.Colors.accentSubtle : Color.clear)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.border,
                                    lineWidth: selected ? 1.5 : 1
                                )
                        )
                )
                .foregroundStyle(
                    selected ? ConsensusTheme.Colors.accent : ConsensusTheme.Colors.textSecondary
                )
        }
        .buttonStyle(.plain)
    }

    private func appearancesSection(voice: VoiceIdentity) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("APPEARANCES")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                .tracking(1.0)

            if voice.projectAppearances.isEmpty {
                Text("This voice hasn't been linked to any project yet.")
                    .font(ConsensusType.displayCaption)
                    .foregroundStyle(ConsensusTheme.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(voice.projectAppearances.prefix(8), id: \.projectID) { appearance in
                        HStack {
                            Text(appearance.speakerID)
                                .font(ConsensusType.monoMetric)
                            Text("in project")
                                .font(ConsensusType.displayCaption)
                                .foregroundStyle(ConsensusTheme.Colors.textSecondary)
                            Spacer()
                            Text(Self.format(appearance.seenAt))
                                .font(ConsensusType.displayCaption)
                                .foregroundStyle(ConsensusTheme.Colors.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func dangerSection(voice: VoiceIdentity) -> some View {
        VStack(alignment: .leading, spacing: ConsensusTheme.Spacing.xs) {
            Text("DANGER")
                .font(ConsensusType.displayEyebrow)
                .foregroundStyle(ConsensusTheme.Colors.danger)
                .tracking(1.0)
            Button(role: .destructive) {
                delete(voice: voice)
            } label: {
                Label("Delete voice", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .foregroundStyle(ConsensusTheme.Colors.danger)
        }
    }

    // MARK: - Actions

    private func rename(voice: VoiceIdentity, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != voice.displayName else { return }
        var updated = voice
        updated.displayName = trimmed
        do {
            try viewModel.voiceStore.update(updated)
            editingName = trimmed
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func toggle(tag: VoiceTag, on voice: VoiceIdentity) {
        var updated = voice
        if updated.tags.contains(tag) {
            updated.tags.remove(tag)
        } else {
            updated.tags.insert(tag)
        }
        do {
            try viewModel.voiceStore.update(updated)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func delete(voice: VoiceIdentity) {
        let alert = NSAlert()
        alert.messageText = "Delete \(voice.displayName)?"
        alert.informativeText = "The voice sample and all project cross-references will be removed. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try viewModel.voiceStore.remove(id: voice.id)
            if selectedVoiceID == voice.id { selectedVoiceID = nil }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Filtering

    private var filteredVoices: [VoiceIdentity] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = viewModel.voiceStore.library.voices.sorted { $0.lastSeenAt > $1.lastSeenAt }
        if q.isEmpty { return sorted }
        return sorted.filter { $0.displayName.lowercased().contains(q) }
    }

    private var selectedVoice: VoiceIdentity? {
        guard let id = selectedVoiceID else { return nil }
        return viewModel.voiceStore.library.voices.first(where: { $0.id == id })
    }

    private static func subtitle(for voice: VoiceIdentity) -> String {
        if voice.tags.contains(.myVoice) { return "My voice" }
        if voice.tags.contains(.frequentCaller) { return "Frequent caller" }
        if !voice.projectAppearances.isEmpty {
            return "\(voice.projectAppearances.count) project\(voice.projectAppearances.count == 1 ? "" : "s")"
        }
        return "—"
    }

    private static func format(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}

// MARK: - Helpers

private struct VoiceAvatar: View {
    let voice: VoiceIdentity

    var body: some View {
        let seed = abs(voice.id.uuidString.hashValue)
        let palette = ConsensusTheme.Colors.speakerPalette
        let color = palette[seed % palette.count]
        let initial = voice.displayName.first.map(String.init)?.uppercased() ?? "?"
        return ZStack {
            Circle().fill(color.opacity(0.25))
            Circle().stroke(color, lineWidth: 1)
            Text(initial)
                .font(ConsensusType.displayCaption.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(width: 28, height: 28)
    }
}

/// Very small wrapping horizontal stack for the tag chips. SwiftUI's
/// `FlowLayout` isn't available on macOS 15 — this is a shim.
private struct WrapHStack<Content: View>: View {
    let spacing: CGFloat = ConsensusTheme.Spacing.xs
    let rowSpacing: CGFloat = ConsensusTheme.Spacing.xs
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Simple: let macOS's HStack overflow naturally. For the small
        // fixed set of built-in tags in `tagsSection`, a single-row stack
        // comfortably fits at 520 pt detail width.
        HStack(spacing: spacing) {
            content()
        }
    }
}
