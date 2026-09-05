import Foundation

/// User settings.
///
/// There is deliberately no preferences window. Settings sprawl is the main
/// thing that makes general-purpose monitors tiresome, and this app has
/// exactly one user. A small JSON file that reloads on save does the same job
/// without a UI to build, lay out, validate or maintain.
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
    }

    static let `default` = Config()

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
final class ConfigStore {
    private(set) var config: Config
    private let url: URL
    private let directory: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    /// Called on the main queue whenever the file changes materially.
    var onChange: ((Config) -> Void)?

    init() {
        directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vitals", isDirectory: true)
        url = directory.appendingPathComponent("config.json")

        config = Self.read(from: url) ?? .default
        Self.writeDefaultIfMissing(at: url, directory: directory)

        watchDirectory()
        watchFile()
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
    }

    // MARK: - Reading and writing

    private static func read(from url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        // A hand-edited file will have mistakes in it. Falling back to the
        // last good config beats crashing or showing an empty menu bar.
        guard let decoded = try? decoder.decode(Config.self, from: data) else { return nil }
        return decoded.validated()
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
        guard let updated = Self.read(from: url), updated != config else { return }
        config = updated
        onChange?(updated)
    }
}
