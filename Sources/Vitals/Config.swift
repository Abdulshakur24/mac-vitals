import Combine
import Foundation

/// User settings.
///
/// The JSON file is the source of truth and reloads on save. The settings pane
/// in the panel edits that same file, so there is one place settings live, and
/// the list here stays short on purpose: sprawl is the main thing that makes
/// general-purpose monitors tiresome.
struct Config: Codable, Equatable {
    /// Seconds between samples. Automatically doubled while the machine is in
    /// Low Power Mode.
    var sampleInterval: Double = 1.0
    /// Which metrics appear in the menu bar, in display order. Removing an
    /// entry hides it; reordering reorders the readout.
    ///
    /// The order is also the order of importance. When the menu bar runs short
    /// of space the readout gives ground from the end of this list first, so
    /// the first entry is both the leftmost and the last one standing.
    var menuBar: [Metric] = [.cpu, .memory, .network, .temperature]
    /// Fractions above which a readout turns orange.
    var thresholds = Thresholds()

    struct Thresholds: Codable, Equatable {
        var cpu: Double = 0.7
        var temperature: Double = 90
        var diskFree: Double = 0.1

        // Synthesized decoding demands every key, so a hand-edited file that
        // sets only `cpu` would be thrown away whole. Missing keys take the
        // default instead.
        init(cpu: Double = 0.7, temperature: Double = 90, diskFree: Double = 0.1) {
            self.cpu = cpu
            self.temperature = temperature
            self.diskFree = diskFree
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Thresholds()
            cpu = try container.decodeIfPresent(Double.self, forKey: .cpu) ?? defaults.cpu
            temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
            diskFree = try container.decodeIfPresent(Double.self, forKey: .diskFree) ?? defaults.diskFree
        }
    }

    static let `default` = Config()

    private enum CodingKeys: String, CodingKey {
        case sampleInterval, menuBar, thresholds
    }

    /// Any key may be left out, and a metric name this build does not know is
    /// skipped rather than failing the file — a typo in one entry should cost
    /// that entry, not every other setting in the file. A value of the wrong
    /// type is still an error, and `ConfigStore` keeps the last good config.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        sampleInterval = try container.decodeIfPresent(Double.self, forKey: .sampleInterval)
            ?? defaults.sampleInterval
        menuBar = try container.decodeIfPresent([String].self, forKey: .menuBar)
            .map { $0.compactMap(Metric.init(rawValue:)) } ?? defaults.menuBar
        thresholds = try container.decodeIfPresent(Thresholds.self, forKey: .thresholds)
            ?? defaults.thresholds
    }

    init() {}

    /// Metric names in a config file that this build does not know.
    static func unknownMetrics(in data: Data) -> [String] {
        struct Names: Decodable { var menuBar: [String]? }
        guard let names = try? JSONDecoder().decode(Names.self, from: data).menuBar else { return [] }
        return names.filter { Metric(rawValue: $0) == nil }
    }

    /// Adds a metric at the end, the lowest priority, or removes it. The last
    /// one stays, because an empty menu bar leaves no way back to the settings.
    func togglingMetric(_ metric: Metric) -> Config {
        var result = self
        if let index = menuBar.firstIndex(of: metric) {
            if menuBar.count > 1 { result.menuBar.remove(at: index) }
        } else {
            result.menuBar.append(metric)
        }
        return result
    }

    /// Moves a metric along the list, which changes both where it is drawn and
    /// how long it survives when the menu bar is short of room.
    func movingMetric(_ metric: Metric, by offset: Int) -> Config {
        guard let index = menuBar.firstIndex(of: metric),
              menuBar.indices.contains(index + offset) else { return self }
        var result = self
        result.menuBar.swapAt(index, index + offset)
        return result
    }

    /// Applies bounds that keep a hand-edited file from producing a broken or
    /// battery-hostile app: a 0.05s interval would spin the CPU, and an empty
    /// metric list would leave an invisible status item with no way back.
    func validated() -> Config {
        var result = self
        result.sampleInterval = sampleInterval.isFinite ? min(max(sampleInterval, 0.5), 60) : 1
        result.thresholds.cpu = thresholds.cpu.isFinite ? min(max(thresholds.cpu, 0), 1) : 0.7
        result.thresholds.diskFree = thresholds.diskFree.isFinite ? min(max(thresholds.diskFree, 0), 1) : 0.1
        result.thresholds.temperature = thresholds.temperature.isFinite ? min(max(thresholds.temperature, 1), 130) : 90
        // A metric listed twice would be drawn twice, and the two copies would
        // be indistinguishable to the readout's layout, which identifies blocks
        // by their metric.
        var seen: Set<Metric> = []
        result.menuBar = result.menuBar.filter { seen.insert($0).inserted }
        if result.menuBar.isEmpty {
            result.menuBar = Config.default.menuBar
        }
        return result
    }
}

/// Loads `~/.config/vitals/config.json` and reports changes to it.
///
/// Both the file and its containing directory are watched, because neither
/// alone catches every way an edit can arrive:
///
///   - A file-level watch sees in-place writes (`vim` with backupcopy, shell
///     redirection) but dies with the inode when an editor saves by writing a
///     temporary file and renaming it over the target — the common case.
///   - A directory-level watch sees that rename, but not an in-place write,
///     since modifying a file's contents does not modify its directory entry.
///
/// So the file watch handles content changes and rebinds itself whenever the
/// inode is replaced, and the directory watch covers the file being created or
/// swapped in while no file watch is active.
final class ConfigStore: ObservableObject {
    @Published private(set) var config: Config
    /// What is wrong with the file on disk, in words, or nil if nothing is.
    /// A mistake used to mean nothing happened and nothing said why.
    @Published private(set) var problem: String?
    /// False while the file cannot be parsed. Saving would replace it, and a
    /// half-finished hand edit is not this app's to throw away.
    @Published private(set) var canSave = true
    let url: URL
    private let directory: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    /// Called on the main queue whenever the file changes materially.
    var onChange: ((Config) -> Void)?

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vitals", isDirectory: true)
    }

    init(directory: URL = ConfigStore.defaultDirectory) {
        self.directory = directory
        url = directory.appendingPathComponent("config.json")

        let loaded = Self.load(from: url)
        config = loaded.config ?? .default
        problem = loaded.problem
        canSave = !loaded.isInvalid
        Self.writeDefaultIfMissing(at: url, directory: directory)

        watchDirectory()
        watchFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    // MARK: - Reading and writing

    private struct Loaded {
        var config: Config?
        var problem: String?
        var isInvalid = false
    }

    private static func load(from url: URL) -> Loaded {
        // A missing file is the first run, or a deletion: nothing to report.
        guard let data = try? Data(contentsOf: url) else { return Loaded() }
        do {
            let decoded = try JSONDecoder().decode(Config.self, from: data).validated()
            let unknown = Config.unknownMetrics(in: data)
            let quoted = unknown.map { "“\($0)”" }.joined(separator: ", ")
            return Loaded(config: decoded, problem: unknown.isEmpty ? nil : "Unknown metric \(quoted) ignored")
        } catch {
            // A hand-edited file will have mistakes in it. Falling back to the
            // last good config beats crashing or showing an empty menu bar.
            return Loaded(problem: describe(error), isInvalid: true)
        }
    }

    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error as? DecodingError {
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "“\(path(context))” has the wrong type"
        case .dataCorrupted(let context):
            let underlying = context.underlyingError as NSError?
            return underlying?.userInfo[NSDebugDescriptionErrorKey] as? String ?? "Not valid JSON"
        default:
            return "Not valid JSON"
        }
    }

    /// Replaces the file with `new`, or returns false if the file on disk is
    /// one this must not overwrite.
    ///
    /// `config` is updated before the write, so the watcher's reload finds
    /// nothing new and the change is reported exactly once.
    @discardableResult
    func save(_ new: Config) -> Bool {
        reload()
        guard canSave else { return false }
        let validated = new.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(validated), (try? data.write(to: url, options: .atomic)) != nil else {
            return false
        }
        problem = nil
        guard validated != config else { return true }
        config = validated
        onChange?(validated)
        return true
    }

    /// Writes a commented starting point so the file is discoverable — the app
    /// has no settings UI to point at.
    private static func writeDefaultIfMissing(at url: URL, directory: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Config.default) else { return }
        try? data.write(to: url)
    }

    // MARK: - Watching

    /// Catches the file being created, replaced by rename, or removed.
    private func watchDirectory() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A rename swaps in a new inode, so the file watch is now bound to
            // a dead one and has to be re-established before reloading.
            watchFile()
            reload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        directorySource = source
    }

    /// Catches writes to the file's existing inode.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let current = fileSource else { return }
            let events = current.data

            reload()

            // The inode this watch holds is gone. Rebind to whatever now lives
            // at the path, or the next save would go unnoticed.
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                watchFile()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        fileSource = source
    }

    private func reload() {
        let loaded = Self.load(from: url)
        if problem != loaded.problem { problem = loaded.problem }
        if canSave == loaded.isInvalid { canSave = !loaded.isInvalid }
        guard let updated = loaded.config, updated != config else { return }
        config = updated
        onChange?(updated)
    }
}
