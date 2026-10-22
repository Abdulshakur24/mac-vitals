import SwiftUI

@MainActor
struct TopAppsView: View {
    let sample: ProcessSample
    @State private var selection: ProcessListSelection
    @State private var icons: [URL: NSImage] = [:]
    @State private var pendingForceQuit: AppQuitRequest?
    @State private var showForceConfirmation = false
    @State private var feedback: AppQuitFeedback?
    private let quitController: AppQuitController

    init(sample: ProcessSample, selection: ProcessListSelection = .init(), quitController: AppQuitController? = nil) {
        self.sample = sample
        _selection = State(initialValue: selection)
        self.quitController = quitController ?? AppQuitController()
    }

    private var liveIDs: Set<ProcessGroup.ID> { Set(sample.groups.map(\.id)) }
    private var visibleAppURLs: Set<URL> {
        Set(selection.displayed(in: sample).compactMap { $0.app?.bundleURL })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top apps").fontWeight(.semibold)
                Spacer()
                Picker("Include processes", selection: $selection.filter) {
                    ForEach(ProcessFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .help("All includes system services and command-line tools without an app bundle.")
            }

            HStack {
                Text("Sort by").foregroundStyle(.secondary)
                Picker("Rank apps by", selection: $selection.sort) {
                    ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                Spacer(minLength: 0)
            }

            switch sample.state {
            case .sampling:
                Text("Sampling…").foregroundStyle(.secondary)
            case .unavailable:
                Text("Process readings unavailable. Retrying…").foregroundStyle(.secondary)
            case .ready:
                rankings
            }

            if let feedback {
                HStack(alignment: .top, spacing: 6) {
                    Text(feedback.message)
                        .foregroundStyle(feedback.isError ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { self.feedback = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss app action message")
                }
            }

            Text("100% CPU = one fully busy core")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text("Resident memory · totals can include shared pages")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("Force quit \(pendingForceQuit?.name ?? "app")?",
                            isPresented: $showForceConfirmation, titleVisibility: .visible,
                            presenting: pendingForceQuit) { request in
            Button("Force Quit", role: .destructive) { perform(request, mode: .forceQuit) }
            Button("Cancel", role: .cancel) { pendingForceQuit = nil }
        } message: { request in
            Text(request.confirmationMessage)
        }
        .onChange(of: liveIDs) { _, _ in
            selection.retainLiveGroups(in: sample)
            guard sample.state == .ready else { return }
            let liveURLs = Set(sample.groups.compactMap { $0.app?.bundleURL })
            icons = icons.filter { liveURLs.contains($0.key) }
        }
        .onChange(of: visibleAppURLs, initial: true) { _, urls in
            // Resolve icons when a row first becomes visible, never per tick.
            let running = NSWorkspace.shared.runningApplications
            for url in urls where icons[url] == nil {
                icons[url] = running.first { $0.bundleURL?.standardizedFileURL == url }?.icon
                    ?? NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }

    @ViewBuilder
    private var rankings: some View {
        let ranked = sample.ranked(by: selection.sort, filter: selection.filter)
        if ranked.isEmpty {
            Text(selection.filter == .apps ? "No apps available. Try All for other processes." : "No processes available.")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Text(selection.filter == .apps ? "App" : "App / process")
                Spacer(minLength: 0)
                Text("CPU").frame(width: 48, alignment: .trailing)
                Text("Resident").frame(width: 68, alignment: .trailing)
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(selection.displayed(in: sample)) { group in
                    groupRow(group)
                }
            }

            if ranked.count > 5 {
                Button(selection.showAll ? "Show fewer" : "Show all (\(ranked.count))") {
                    selection.showAll.toggle()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func groupRow(_ group: ProcessGroup) -> some View {
        let expanded = selection.expanded.contains(group.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button {
                    if expanded { selection.expanded.remove(group.id) }
                    else { selection.expanded.insert(group.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 8)
                        icon(group)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).lineLimit(1).truncationMode(.middle)
                            Text("\(group.processes.count) \(group.processes.count == 1 ? "process" : "processes")")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        values(cpu: group.cpu, memory: group.memory)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .help(group.name)
                .accessibilityLabel("\(group.name), \(Format.percent(group.cpu)) CPU, \(Format.bytes(group.memory)) resident memory, \(group.processes.count) processes")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide individual processes")

                if group.app != nil {
                    Menu {
                        appActions(group)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 18)
                    .disabled(!quitController.canQuit(group))
                    .help("Actions for \(group.name)")
                    .accessibilityLabel("Actions for \(group.name)")
                } else {
                    Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
                }
            }
            .contextMenu {
                if quitController.canQuit(group) { appActions(group) }
            }

            if expanded {
                VStack(spacing: 6) {
                    ForEach(selection.sort.sorted(group.processes)) { row in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name).lineLimit(1).truncationMode(.middle)
                                Text("PID \(row.pid)").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            values(cpu: row.cpu, memory: row.memory)
                            Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
                        }
                        .help("\(row.name) · PID \(row.pid)")
                    }
                }
                .padding(.leading, 18)
                .padding(.vertical, 5)
            }
        }
    }

    @ViewBuilder
    private func appActions(_ group: ProcessGroup) -> some View {
        Button("Quit \(group.name)") { requestQuit(group, mode: .quit) }
        Button("Force Quit…", role: .destructive) { requestQuit(group, mode: .forceQuit) }
    }

    private func requestQuit(_ group: ProcessGroup, mode: AppQuitMode) {
        do {
            let request = try quitController.prepare(group)
            if mode == .forceQuit {
                pendingForceQuit = request
                showForceConfirmation = true
            } else {
                perform(request, mode: mode)
            }
        } catch {
            feedback = AppQuitFeedback(message: error.localizedDescription, isError: true)
        }
    }

    private func perform(_ request: AppQuitRequest, mode: AppQuitMode) {
        let result = quitController.perform(request, mode: mode)
        feedback = AppQuitController.feedback(for: result, request: request, mode: mode)
        pendingForceQuit = nil
    }

    @ViewBuilder
    private func icon(_ group: ProcessGroup) -> some View {
        if let url = group.app?.bundleURL, let image = icons[url] {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            Image(systemName: group.app == nil ? "terminal" : "app")
                .foregroundStyle(.secondary).frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private func values(cpu: Double, memory: UInt64) -> some View {
        Group {
            Text(Format.percent(cpu)).frame(width: 48, alignment: .trailing)
            Text(Format.bytes(memory)).frame(width: 68, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
}
