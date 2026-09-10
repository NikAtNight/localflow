import AppKit
import AVFoundation
import SwiftUI

/// Review is explicit because recognition and cleanup text can differ from the recording.
@MainActor
struct PersonalVoicePane: View {
    @ObservedObject var model: SettingsModel
    @State private var archive: PersonalVoiceStore.Snapshot?
    @State private var selectedID: UUID?
    @State private var drafts: [UUID: String] = [:]
    @State private var player: AVAudioPlayer?
    @State private var busy = false
    @State private var confirmingDeletion = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private let store = PersonalVoiceStore.shared

    private var selectedClip: PersonalVoiceStore.Clip? {
        archive?.clips.first { $0.id == selectedID }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Collect my dictations for a personal voice dataset", isOn: $model.savePersonalVoice)
                if let archive {
                    Text("\(archive.clips.count) clips · \(byteLabel(archive.usedBytes)) of \(byteLabel(archive.maxBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open archive folder", action: openFolder)
                    Spacer()
                    Button("Refresh") { Task { await refresh() } }
                }
                Button("Import existing diagnostic recordings") {
                    perform {
                        let count = try await store.importDiagnostics()
                        statusMessage = "Imported \(count) recordings. Each needs transcript review."
                    }
                }
                Button("Export approved dataset…", action: chooseExportFolder)
                    .disabled(!(archive?.clips.contains(where: \.approved) ?? false))
            } header: {
                Text("Personal voice archive")
            } footer: {
                Text("LocalFlow Local only. Keeps one original recording per dictation until you delete it. New audio saves pause at 20 GB; you can still edit transcripts. Turning this off stops new saves and keeps existing clips. Diagnostic recordings retain their separate 7-day, 1 GB limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let issue = archive?.issue {
                Section { Text(issue).foregroundStyle(.orange).textSelection(.enabled) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let statusMessage {
                Section { Text(statusMessage).font(.caption).textSelection(.enabled) }
            }

            Section("Recordings") {
                if let clips = archive?.clips, !clips.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(clips) { clip in
                                Button {
                                    player?.stop()
                                    selectedID = clip.id
                                } label: {
                                    clipRow(clip)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selectedID == clip.id ? .isSelected : [])
                            }
                        }
                    }
                    .frame(height: 150)
                } else {
                    Text("No saved clips. Enable collection or import existing diagnostic recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let clip = selectedClip {
                reviewSection(clip)
            }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .overlay(alignment: .topTrailing) {
            if busy { ProgressView().controlSize(.small).padding() }
        }
        .task { await refresh() }
        .onDisappear { player?.stop() }
        .confirmationDialog(
            "Delete this personal voice recording?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            if let id = selectedID {
                Button("Delete recording", role: .destructive) {
                    player?.stop()
                    perform {
                        try await store.delete(id: id)
                        drafts.removeValue(forKey: id)
                        selectedID = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the audio and transcript from this archive. Existing diagnostic copies and exports are kept. This can't be undone.")
        }
    }

    private func clipRow(_ clip: PersonalVoiceStore.Clip) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(clip.reviewedTranscript ?? clip.rawTranscript)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f s · %.0f Hz", clip.duration, clip.sampleRate))
                    .font(.caption)
                Text(clip.approved ? "Approved" : "Needs review")
                    .font(.caption)
                    .foregroundStyle(clip.approved ? .green : .secondary)
            }
        }
        .padding(8)
        .background(selectedID == clip.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func reviewSection(_ clip: PersonalVoiceStore.Clip) -> some View {
        Section {
            HStack {
                Button("Play from start") { play(clip.id) }
                Button("Stop") { player?.stop() }
                Spacer()
                Button("Delete…", role: .destructive) { confirmingDeletion = true }
            }
            Text(clip.audioSource == "nativeMono" ? "Microphone recording at original sample rate" : "16 kHz dictation recording")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reason = clip.failureReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("Raw recognition transcript") {
                Text(clip.rawTranscript.isEmpty ? "No raw transcript available." : clip.rawTranscript)
                    .textSelection(.enabled)
            }
            if let finalTranscript = clip.finalTranscript {
                DisclosureGroup("Final dictation text") {
                    Text(finalTranscript).textSelection(.enabled)
                }
            }
            Text("Verbatim transcript")
            TextEditor(text: Binding(
                get: { draft(for: clip) },
                set: { drafts[clip.id] = $0 }
            ))
            .font(.body)
            .frame(minHeight: 110)
            .accessibilityLabel("Verbatim transcript")
            HStack {
                Button("Save draft") { save(clip, approved: false) }
                Spacer()
                Button("Approve transcript") { save(clip, approved: true) }
                    .disabled(draft(for: clip).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Listen and review")
        } footer: {
            Text("Raw recognition can miss or change words. Edit the transcript to match everything spoken, including repetitions. Approve only after listening and checking the words. Saving a draft clears prior approval. Exports include only saved, approved transcripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func draft(for clip: PersonalVoiceStore.Clip) -> String {
        drafts[clip.id] ?? clip.reviewedTranscript ?? clip.rawTranscript
    }

    private func save(_ clip: PersonalVoiceStore.Clip, approved: Bool) {
        let transcript = draft(for: clip)
        perform {
            try await store.updateReview(id: clip.id, transcript: transcript, approved: approved)
            drafts.removeValue(forKey: clip.id)
            statusMessage = approved ? "Transcript approved for export." : "Draft saved. This clip needs approval before export."
        }
    }

    private func play(_ id: UUID) {
        do {
            player?.stop()
            let next = try AVAudioPlayer(contentsOf: store.audioURL(for: id))
            guard next.play() else {
                errorMessage = "Couldn't play this recording."
                return
            }
            player = next
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            try await loadSnapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSnapshot() async throws {
        archive = try await store.snapshot()
        if selectedClip == nil { selectedID = archive?.clips.first?.id }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { busy = false }
            do {
                try await action()
                try await loadSnapshot()
            } catch {
                errorMessage = error.localizedDescription
                try? await loadSnapshot()
            }
        }
    }

    private func openFolder() {
        do {
            try FileManager.default.createDirectory(
                at: PersonalVoiceStore.folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            errorMessage = NSWorkspace.shared.open(PersonalVoiceStore.folder)
                ? nil : "Couldn't open the personal voice folder."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the approved dataset"
        panel.prompt = "Export here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            let count = try await store.exportApproved(to: destination)
            statusMessage = "Exported \(count) approved recordings to \(destination.path)."
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
