import SwiftUI

/// Local-only, on-demand diagnostics. It does no work while dictation is running
/// unless the user explicitly opens or refreshes this pane.
struct DiagnosticsPane: View {
    @State private var snapshot = DiagnosticsSnapshot()
    @State private var expanded: Set<UUID> = []
    @State private var refreshID = 0
    @State private var maximumTraces = 200
    @State private var loading = false
    @State private var loadFailed = false
    @State private var refreshedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Local diagnostics").font(.headline)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID += 1 }
                        .disabled(loading)
                }
                Text("\(AppBuildInfo.current.versionLabel) · \(AppBuildInfo.current.revisionLabel)")
                Text("Built \(AppBuildInfo.current.builtAt)")
                Text("Timing history is kept across updates with no automatic expiry. No transcripts or audio.")
                Text("Dispatch means the paste or typing event was sent. Visible text insertion is not measured; clipboard restoration is a separate event.")
                Text("~/Library/Application Support/LocalFlow Local/Diagnostics")
                    .textSelection(.enabled)
                if let refreshedAt {
                    Text("\(snapshot.traces.count) traces · Updated \(refreshedAt.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding([.horizontal, .top])

            if loadFailed {
                ContentUnavailableView("Couldn't read diagnostics", systemImage: "exclamationmark.triangle",
                                       description: Text("Timing history could not be read or saved. Try Refresh; restart the app after resolving storage problems."))
            } else if snapshot.traces.isEmpty && !loading {
                ContentUnavailableView("No timing events yet", systemImage: "waveform.path.ecg",
                                       description: Text("Complete a dictation, then click Refresh."))
            } else {
                List {
                    if snapshot.hasOlderTraces {
                        Button("Load older traces") { maximumTraces += 200; refreshID += 1 }
                            .disabled(loading)
                    }
                    if snapshot.ignoredTimingLines > 0 {
                        Text("Skipped \(snapshot.ignoredTimingLines) incomplete or unsupported timing records.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.traces) { trace in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expanded.contains(trace.id) },
                            set: { if $0 { expanded.insert(trace.id) } else { expanded.remove(trace.id) } }
                        )) {
                            if expanded.contains(trace.id) {
                                Text(trace.report)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(trace.title) · \(trace.startedAt.formatted(date: .abbreviated, time: .standard))")
                                Text(trace.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: refreshID) { await refresh() }
    }

    @MainActor
    private func refresh() async {
        guard AppIdentity.current.isLocal else { return }
        loading = true
        loadFailed = false
        defer { loading = false }
        let limit = maximumTraces
        do {
            let result = try await Task.detached(priority: .utility) {
                try DiagLog.readHistory(maximumTraces: limit)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = result
            expanded.formIntersection(Set(result.traces.map(\.id)))
            refreshedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
