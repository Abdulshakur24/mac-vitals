import Foundation

struct ProcessIdentity: Equatable, Hashable {
    var pid: Int32
    var started: UInt64
}

struct ProcessApp: Equatable {
    var bundleURL: URL
    var name: String

    /// Helpers can themselves be apps nested in Frameworks or PlugIns. The
    /// outer bundle is the owning app; ancestry and name prefixes are not.
    static func bundleURL(containing executable: URL) -> URL? {
        let components = executable.standardizedFileURL.pathComponents
        guard let index = components.dropLast().firstIndex(where: {
            ($0 as NSString).pathExtension.lowercased() == "app"
        }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])),
                   isDirectory: true)
    }
}

struct ProcessInfoRow: Equatable, Identifiable {
    var id: ProcessIdentity { .init(pid: pid, started: started) }
    var pid: Int32
    var started: UInt64
    var name: String
    var cpu: Double     // 1.0 == one core fully busy; intentionally not capped
    var memory: UInt64 // resident bytes, including shared pages
    var app: ProcessApp? = nil
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory"
    var id: Self { self }

    func precedes(cpu: Double, memory: UInt64, otherCPU: Double, otherMemory: UInt64) -> Bool? {
        switch self {
        case .cpu: return cpu == otherCPU ? nil : cpu > otherCPU
        case .memory: return memory == otherMemory ? nil : memory > otherMemory
        }
    }

    func sorted(_ rows: [ProcessInfoRow]) -> [ProcessInfoRow] {
        rows.sorted {
            precedes(cpu: $0.cpu, memory: $0.memory, otherCPU: $1.cpu, otherMemory: $1.memory)
                ?? ($0.name == $1.name ? $0.pid < $1.pid : $0.name < $1.name)
        }
    }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case apps = "Apps", all = "All"
    var id: Self { self }
}

struct ProcessGroup: Equatable, Identifiable {
    enum ID: Equatable, Hashable {
        case app(URL)
        case process(ProcessIdentity)
    }

    var id: ID
    var name: String
    var app: ProcessApp?
    var processes: [ProcessInfoRow]
    var cpu: Double
    var memory: UInt64

    static func aggregate(_ rows: [ProcessInfoRow]) -> [ProcessGroup] {
        let members = Dictionary(grouping: rows) { row in
            row.app.map { ID.app($0.bundleURL) } ?? .process(row.id)
        }
        return members.map { id, processes in
            let first = processes[0]
            return ProcessGroup(id: id, name: first.app?.name ?? first.name,
                                app: first.app, processes: processes,
                                cpu: processes.reduce(0) { $0 + $1.cpu },
                                memory: processes.reduce(0) { $0 + $1.memory })
        }
    }

    /// A total ordering prevents tied readings from shuffling every tick.
    var sortKey: String {
        switch id {
        case .app(let url): return "app:\(url.path)"
        case .process(let identity): return "process:\(identity.pid):\(identity.started)"
        }
    }
}

struct ProcessSample: Equatable {
    /// `sampling` is a first scan: CPU takes two, so its rows read 0% CPU,
    /// but their resident memory is already real. `ready` has both.
    enum State: Equatable { case sampling, ready, unavailable }

    let state: State
    let rows: [ProcessInfoRow]
    let groups: [ProcessGroup]

    init(rows: [ProcessInfoRow] = [], state: State = .sampling) {
        self.state = state
        self.rows = rows
        groups = ProcessGroup.aggregate(rows)
    }

    // Keep the existing command-line process rankings.
    var topByCPU: [ProcessInfoRow] { Array(ProcessSort.cpu.sorted(rows).prefix(5)) }
    var topByMemory: [ProcessInfoRow] { Array(ProcessSort.memory.sorted(rows).prefix(5)) }

    func ranked(by sort: ProcessSort, filter: ProcessFilter) -> [ProcessGroup] {
        groups.filter { filter == .all || $0.app != nil }.sorted {
            sort.precedes(cpu: $0.cpu, memory: $0.memory, otherCPU: $1.cpu, otherMemory: $1.memory)
                ?? ($0.name == $1.name ? $0.sortKey < $1.sortKey : $0.name < $1.name)
        }
    }
}

/// View state is owned by the panel, which is recreated on each open. Sort
/// and filter are the two choices worth keeping across opens.
struct ProcessListSelection {
    var sort: ProcessSort = .cpu
    var filter: ProcessFilter = .apps
    var showAll = false
    var expanded: Set<ProcessGroup.ID> = []
    /// Row order held while the pointer is over the list. Ranking live moves a
    /// row out from under a click aimed at its actions menu, and one of those
    /// actions is Force Quit. Values keep updating; only the order waits.
    var frozenOrder: [ProcessGroup.ID]?

    private static let sortKey = "apps.sort"
    private static let filterKey = "apps.filter"

    static func saved(in defaults: UserDefaults = .standard) -> ProcessListSelection {
        var selection = ProcessListSelection()
        selection.sort = defaults.string(forKey: sortKey).flatMap(ProcessSort.init) ?? .cpu
        selection.filter = defaults.string(forKey: filterKey).flatMap(ProcessFilter.init) ?? .apps
        return selection
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(sort.rawValue, forKey: Self.sortKey)
        defaults.set(filter.rawValue, forKey: Self.filterKey)
    }

    /// Everything the current sort and filter select, in display order. Groups
    /// that appeared since the freeze follow the frozen ones, and exited groups
    /// simply drop out.
    func ordered(in sample: ProcessSample) -> [ProcessGroup] {
        let ranked = sample.ranked(by: sort, filter: filter)
        guard let frozenOrder else { return ranked }
        let groups = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        let held = Set(frozenOrder)
        return frozenOrder.compactMap { groups[$0] } + ranked.filter { !held.contains($0.id) }
    }

    func displayed(in sample: ProcessSample) -> [ProcessGroup] {
        let groups = ordered(in: sample)
        return showAll ? groups : Array(groups.prefix(5))
    }

    mutating func retainLiveGroups(in sample: ProcessSample) {
        // A failed read is not evidence that the expanded app has exited.
        guard sample.state == .ready else { return }
        expanded.formIntersection(sample.groups.map(\.id))
    }
}
