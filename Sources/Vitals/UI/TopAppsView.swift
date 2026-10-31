import SwiftUI

@MainActor
struct TopAppsView: View {
    let sample: ProcessSample
    @State private var selection: ProcessListSelection
    @State private var icons: [URL: NSImage] = [:]
    @State private var pendingForceQuit: AppQuitRequest?
    @State private var feedback: AppQuitFeedback?
    @State private var hoveredRow: ProcessGroup.ID?
    @FocusState private var focusedActions: ProcessGroup.ID?
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
            HStack(spacing: 6) {
                Toggle("All processes", isOn: Binding(
                    get: { selection.filter == .all },
                    set: { selection.filter = $0 ? .all : .apps }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("Include system services and command-line tools without an app bundle.")
                Spacer(minLength: 0)
                sortHeader(.cpu, title: "CPU", width: 48,
                           help: "100% CPU = one fully busy core. Click to sort.")
                sortHeader(.memory, title: "Memory", width: 68,
                           help: "Resident memory. Totals can include shared pages. Click to sort.")
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }

            switch sample.state {
            case .sampling:
                Text("Sampling…").foregroundStyle(.secondary)
            case .unavailable:
                Text("Process readings unavailable. Retrying…").foregroundStyle(.secondary)
            case .ready:
                rankings
            }

            if let pendingForceQuit { forceQuitConfirmation(pendingForceQuit) }

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

        }
        .onChange(of: selection.sort) { _, _ in selection.frozenOrder = nil; selection.save() }
        .onChange(of: selection.filter) { _, _ in selection.frozenOrder = nil; selection.save() }
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
            VStack(spacing: 2) {
                ForEach(selection.displayed(in: sample)) { group in
                    groupRow(group)
                }
            }
            .onHover { inside in
                selection.frozenOrder = inside ? selection.displayed(in: sample).map(\.id) : nil
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

    /// A column title that doubles as the sort control, like a table's.
    private func sortHeader(_ sort: ProcessSort, title: String, width: CGFloat, help: String) -> some View {
        let active = selection.sort == sort
        return Button { selection.sort = sort } label: {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(title)
                if active { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: active ? .semibold : .regular))
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .help(help)
        .accessibilityLabel("Sort by \(title)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func groupRow(_ group: ProcessGroup) -> some View {
        let expanded = selection.expanded.contains(group.id)
        let showsActions = hoveredRow == group.id || focusedActions == group.id
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
                            if group.processes.count > 1 {
                                Text("\(group.processes.count) processes")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
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
                    .opacity(showsActions ? 1 : 0)
                    .focused($focusedActions, equals: group.id)
                    .disabled(!quitController.canQuit(group))
                    .help("Actions for \(group.name)")
                    .accessibilityLabel("Actions for \(group.name)")
                } else {
                    Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
                }
            }
            .onHover { inside in
                if inside { hoveredRow = group.id }
                else if hoveredRow == group.id { hoveredRow = nil }
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
                                Text("PID \(row.pid)").font(.system(size: 10)).foregroundStyle(.secondary)
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
            } else {
                perform(request, mode: mode)
            }
        } catch {
            feedback = AppQuitFeedback(message: error.localizedDescription, isError: true)
        }
    }

    /// Inline rather than a dialog. The panel is a clear borderless window, and
    /// a sheet on one has no title bar to hang from.
    private func forceQuitConfirmation(_ request: AppQuitRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Force quit \(request.name)?").fontWeight(.semibold)
            Text(request.confirmationMessage).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { pendingForceQuit = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Force Quit", role: .destructive) { perform(request, mode: .forceQuit) }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
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
