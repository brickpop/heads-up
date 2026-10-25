import Foundation

/// One day's completed focus sessions.
public struct FocusDay: Equatable, Sendable {
    public var sessions: Int
    public var minutes: Int

    public init(sessions: Int = 0, minutes: Int = 0) {
        self.sessions = sessions
        self.minutes = minutes
    }
}

/// Where completed sessions are counted, by local day ("2026-10-25").
@MainActor
public protocol FocusHistory: AnyObject {
    func day(_ day: String) -> FocusDay
    func recordSession(minutes: Int, day: String)
}

/// The `focus_day` table of headsup.sqlite. The file is opened at launch if it exists, and
/// created only when the first session completes: a fresh install creates nothing until then.
/// Days older than a week are deleted at launch. If the database can't be used, counts are
/// kept in memory for this run and `lastError` says why.
@MainActor
public final class SQLiteFocusHistory: FocusHistory {
    /// Rows older than this many days are deleted at launch.
    static let keepDays = 7

    private let file: URL
    private var database: Database?
    private var memory: [String: FocusDay] = [:]
    public private(set) var lastError: String?

    public init(folder: URL, today: String) {
        file = folder.appendingPathComponent(Database.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        open()
        prune(before: Self.cutoff(today: today))
    }

    public func day(_ day: String) -> FocusDay {
        if let database {
            do {
                let rows = try database.query("SELECT sessions, minutes FROM focus_day WHERE day = ?", [.text(day)])
                if case .integer(let sessions) = rows.first?[0], case .integer(let minutes) = rows.first?[1] {
                    return FocusDay(sessions: Int(sessions), minutes: Int(minutes))
                }
                return FocusDay()
            } catch {
                lastError = error.description
            }
        }
        return memory[day] ?? FocusDay()
    }

    public func recordSession(minutes: Int, day: String) {
        if database == nil && lastError == nil { open() }
        if let database {
            do {
                try database.execute(
                    """
                    INSERT INTO focus_day (day, sessions, minutes) VALUES (?, 1, ?)
                    ON CONFLICT (day) DO UPDATE SET sessions = sessions + 1, minutes = minutes + excluded.minutes
                    """, [.text(day), .integer(Int64(minutes))])
                return
            } catch {
                lastError = error.description
            }
        }
        var counts = memory[day] ?? FocusDay()
        counts.sessions += 1
        counts.minutes += minutes
        memory[day] = counts
    }

    private func open() {
        do {
            database = try Database(file: file)
        } catch {
            lastError = error.description
        }
    }

    private func prune(before day: String) {
        guard let database else { return }
        do {
            try database.execute("DELETE FROM focus_day WHERE day < ?", [.text(day)])
        } catch {
            lastError = error.description
        }
    }

    /// The first day to keep: a week before today. Days are ISO dates, so they sort as text.
    static func cutoff(today: String) -> String {
        guard let date = FocusDayFormat.date(today) else { return today }
        return FocusDayFormat.string(date.addingTimeInterval(-Double(keepDays) * 86_400))
    }
}

/// Counts in memory only, for previews and tests.
@MainActor
public final class MemoryFocusHistory: FocusHistory {
    private var days: [String: FocusDay] = [:]

    public init() {}

    public func day(_ day: String) -> FocusDay { days[day] ?? FocusDay() }

    public func recordSession(minutes: Int, day: String) {
        var counts = days[day] ?? FocusDay()
        counts.sessions += 1
        counts.minutes += minutes
        days[day] = counts
    }
}

/// Local calendar days as "yyyy-MM-dd", the `focus_day` key.
public enum FocusDayFormat {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
