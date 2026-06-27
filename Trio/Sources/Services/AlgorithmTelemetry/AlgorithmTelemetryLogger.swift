import Foundation

/// Local append-only JSONL files under the app's documents directory. One file per day per
/// type (events.jsonl, loop.jsonl, summary.jsonl, settings.json). The AlgorithmTelemetryManager pushes
/// these files to the GitHub `telemetry` branch on a schedule; this class is the on-disk
/// staging buffer.
///
/// Append is the only write operation — never edit prior rows. This makes the file
/// crash-safe and avoids contention with the push side that reads the same file.
final class AlgorithmTelemetryLogger {
    enum FileKind: String {
        case events
        case loop
        case summary
        case settings // not JSONL — daily JSON snapshot, one object per file
    }

    private let queue = DispatchQueue(label: "AlgorithmTelemetryLogger.queue", qos: .utility)
    private let fileManager = FileManager.default
    /// Folder partitioning uses LOCAL date so each calendar day maps to one folder
    /// from the user's perspective (matches the wall clock + pump). Row-level
    /// timestamps remain UTC ISO-8601 for unambiguous sorting/analysis.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    /// Root directory on disk: ~/Documents/telemetry/
    private var rootDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("telemetry", isDirectory: true)
    }

    func appendEvent(_ event: AlgorithmTelemetryEvent) {
        write(line: event, kind: .events, on: event.timestamp)
    }

    func appendLoopSample(_ sample: AlgorithmTelemetryLoopSample) {
        write(line: sample, kind: .loop, on: sample.timestamp)
    }

    func appendSummary(_ summary: AlgorithmTelemetryWindowSummary) {
        write(line: summary, kind: .summary, on: summary.closedAt)
    }

    /// Daily settings snapshot is a single-object file (overwritten in place each push).
    func writeSettingsSnapshot(_ snapshot: AlgorithmTelemetrySettingsSnapshot) {
        queue.sync {
            do {
                let url = filePath(kind: .settings, on: snapshot.timestamp)
                try ensureDirectory(for: url)
                let data = try AlgorithmTelemetryCoding.encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                debug(.service, "[Telemetry] settings snapshot write failed: \(error)")
            }
        }
    }

    /// Returns all files (URL + relative path within telemetry/) that are pending push.
    /// Caller decides cutoff dates etc. — the logger just reports what exists on disk.
    func enumerateFiles() -> [(localURL: URL, repoPath: String)] {
        queue.sync {
            guard fileManager.fileExists(atPath: rootDir.path) else { return [] }
            var results: [(URL, String)] = []
            let monthDirs = (try? fileManager.contentsOfDirectory(atPath: rootDir.path)) ?? []
            for month in monthDirs.sorted() {
                let monthURL = rootDir.appendingPathComponent(month)
                let dayDirs = (try? fileManager.contentsOfDirectory(atPath: monthURL.path)) ?? []
                for day in dayDirs.sorted() {
                    let dayURL = monthURL.appendingPathComponent(day)
                    let files = (try? fileManager.contentsOfDirectory(atPath: dayURL.path)) ?? []
                    for file in files.sorted() {
                        let url = dayURL.appendingPathComponent(file)
                        // Repo path = "telemetry/YYYY-MM/DD/file" (matches local layout)
                        let repoPath = "telemetry/\(month)/\(day)/\(file)"
                        results.append((url, repoPath))
                    }
                }
            }
            return results
        }
    }

    /// Delete on-disk files older than `daysToKeep`. Caller decides cadence.
    func purgeLocal(olderThan daysToKeep: Int) {
        queue.sync {
            guard fileManager.fileExists(atPath: rootDir.path) else { return }
            let cutoff = Date().addingTimeInterval(-Double(daysToKeep) * 86_400)
            let monthDirs = (try? fileManager.contentsOfDirectory(atPath: rootDir.path)) ?? []
            for month in monthDirs {
                let monthURL = rootDir.appendingPathComponent(month)
                let dayDirs = (try? fileManager.contentsOfDirectory(atPath: monthURL.path)) ?? []
                for day in dayDirs {
                    let dayURL = monthURL.appendingPathComponent(day)
                    if let parsedDate = parseYearMonthDay(month: month, day: day), parsedDate < cutoff {
                        // Purge loop.jsonl in particular (highest volume), keep summaries forever.
                        let files = (try? fileManager.contentsOfDirectory(atPath: dayURL.path)) ?? []
                        for file in files {
                            if file == FileKind.summary.rawValue + ".jsonl" { continue }
                            try? fileManager.removeItem(at: dayURL.appendingPathComponent(file))
                        }
                    }
                }
            }
        }
    }

    /// Wipe everything in the local telemetry/ directory. Used by the settings "Reset" button.
    func purgeAll() {
        queue.sync {
            try? fileManager.removeItem(at: rootDir)
        }
    }

    // MARK: - Helpers

    private func write<T: Encodable>(line: T, kind: FileKind, on date: Date) {
        queue.async {
            do {
                let url = self.filePath(kind: kind, on: date)
                try self.ensureDirectory(for: url)

                let lineData = try AlgorithmTelemetryCoding.encoder.encode(line)
                guard let lineString = String(data: lineData, encoding: .utf8) else { return }
                let withNewline = lineString + "\n"

                if self.fileManager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    if let data = withNewline.data(using: .utf8) {
                        try handle.write(contentsOf: data)
                    }
                } else {
                    try withNewline.data(using: .utf8)?.write(to: url, options: .atomic)
                }
            } catch {
                debug(.service, "[Telemetry] append failed for \(kind.rawValue): \(error)")
            }
        }
    }

    private func filePath(kind: FileKind, on date: Date) -> URL {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let yearMonth = String(format: "%04d-%02d", comps.year ?? 1970, comps.month ?? 1)
        let day = String(format: "%02d", comps.day ?? 1)
        let ext = kind == .settings ? "json" : "jsonl"
        return rootDir
            .appendingPathComponent(yearMonth, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(kind.rawValue).\(ext)")
    }

    private func ensureDirectory(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func parseYearMonthDay(month: String, day: String) -> Date? {
        let comps = month.split(separator: "-")
        guard comps.count == 2,
              let year = Int(comps[0]),
              let mo = Int(comps[1]),
              let d = Int(day) else { return nil }
        var dc = DateComponents()
        dc.year = year
        dc.month = mo
        dc.day = d
        dc.timeZone = .current
        return calendar.date(from: dc)
    }
}
