// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct ReminderLocalDate: Codable, Equatable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .autoupdatingCurrent) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    static func < (lhs: ReminderLocalDate, rhs: ReminderLocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func date(in calendar: Calendar = .autoupdatingCurrent) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

enum ReminderRecurrence: String, Codable, CaseIterable, Sendable {
    case none
    case weekly
    case monthly
    case yearly

    var displayName: String {
        switch self {
        case .none: return "Once"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

struct DateReminder: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var anchorDate: ReminderLocalDate
    var recurrence: ReminderRecurrence
    var warningDays: Int
    var completedThrough: ReminderLocalDate?

    init(
        id: UUID = UUID(),
        title: String,
        anchorDate: ReminderLocalDate,
        recurrence: ReminderRecurrence,
        warningDays: Int,
        completedThrough: ReminderLocalDate? = nil
    ) {
        self.id = id
        self.title = title
        self.anchorDate = anchorDate
        self.recurrence = recurrence
        self.warningDays = warningDays
        self.completedThrough = completedThrough
    }
}

enum ReminderUrgency: Int, Sendable {
    case due = 0
    case warning = 1
    case normal = 2
}

struct ReminderDashboardItem: Sendable {
    let reminder: DateReminder
    let dueDate: ReminderLocalDate
    let daysUntilDue: Int
    let urgency: ReminderUrgency
}

enum ReminderSchedule {
    static func dashboardItems(
        from reminders: [DateReminder],
        today: ReminderLocalDate = ReminderLocalDate(Date()),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ReminderDashboardItem] {
        reminders.compactMap { reminder in
            guard let dueDate = nextDueDate(for: reminder, calendar: calendar),
                  let days = days(from: today, to: dueDate, calendar: calendar) else {
                return nil
            }

            let urgency: ReminderUrgency
            if days <= 0 {
                urgency = .due
            } else if days <= reminder.warningDays {
                urgency = .warning
            } else {
                urgency = .normal
            }
            return ReminderDashboardItem(
                reminder: reminder,
                dueDate: dueDate,
                daysUntilDue: days,
                urgency: urgency
            )
        }
        .sorted {
            if $0.urgency.rawValue != $1.urgency.rawValue {
                return $0.urgency.rawValue < $1.urgency.rawValue
            }
            if $0.dueDate != $1.dueDate {
                return $0.dueDate < $1.dueDate
            }
            return $0.reminder.title.localizedCaseInsensitiveCompare($1.reminder.title) == .orderedAscending
        }
    }

    static func nextDueDate(
        for reminder: DateReminder,
        calendar: Calendar = .autoupdatingCurrent
    ) -> ReminderLocalDate? {
        guard reminder.recurrence != .none else {
            return reminder.anchorDate
        }
        guard let completedThrough = reminder.completedThrough else {
            return reminder.anchorDate
        }
        return firstOccurrence(
            for: reminder,
            after: completedThrough,
            calendar: calendar
        )
    }

    static func completed(_ reminder: DateReminder, on today: ReminderLocalDate) -> DateReminder? {
        guard reminder.recurrence != .none else {
            return nil
        }
        var updated = reminder
        updated.completedThrough = today
        return updated
    }

    private static func firstOccurrence(
        for reminder: DateReminder,
        after threshold: ReminderLocalDate,
        calendar: Calendar
    ) -> ReminderLocalDate? {
        if threshold < reminder.anchorDate {
            return reminder.anchorDate
        }

        guard let thresholdDate = threshold.date(in: calendar),
              let anchorDate = reminder.anchorDate.date(in: calendar) else {
            return nil
        }

        switch reminder.recurrence {
        case .none:
            return reminder.anchorDate
        case .weekly:
            let anchorWeekday = calendar.component(.weekday, from: anchorDate)
            guard var candidate = calendar.date(byAdding: .day, value: 1, to: thresholdDate) else {
                return nil
            }
            for _ in 0..<7 {
                if calendar.component(.weekday, from: candidate) == anchorWeekday {
                    return ReminderLocalDate(candidate, calendar: calendar)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return nil
                }
                candidate = next
            }
        case .monthly:
            var components = calendar.dateComponents([.year, .month], from: thresholdDate)
            for _ in 0..<2400 {
                if let candidate = clampedDate(
                    year: components.year ?? threshold.year,
                    month: components.month ?? threshold.month,
                    preferredDay: reminder.anchorDate.day,
                    calendar: calendar
                ), candidate > threshold, candidate >= reminder.anchorDate {
                    return candidate
                }
                guard let monthDate = calendar.date(from: components),
                      let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthDate) else {
                    return nil
                }
                components = calendar.dateComponents([.year, .month], from: nextMonth)
            }
        case .yearly:
            var year = threshold.year
            for _ in 0..<400 {
                if let candidate = clampedDate(
                    year: year,
                    month: reminder.anchorDate.month,
                    preferredDay: reminder.anchorDate.day,
                    calendar: calendar
                ), candidate > threshold, candidate >= reminder.anchorDate {
                    return candidate
                }
                year += 1
            }
        }
        return nil
    }

    private static func clampedDate(
        year: Int,
        month: Int,
        preferredDay: Int,
        calendar: Calendar
    ) -> ReminderLocalDate? {
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            return nil
        }
        return ReminderLocalDate(year: year, month: month, day: min(preferredDay, dayRange.count))
    }

    private static func days(
        from start: ReminderLocalDate,
        to end: ReminderLocalDate,
        calendar: Calendar
    ) -> Int? {
        guard let startDate = start.date(in: calendar),
              let endDate = end.date(in: calendar) else {
            return nil
        }
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
    }
}

private struct ReminderStoreDocument: Codable {
    let version: Int
    var reminders: [DateReminder]
}

final class ReminderStore: @unchecked Sendable {
    static let shared = ReminderStore()

    private let lock = NSLock()
    private let fileManager: FileManager
    private let storageURL: URL
    private var reminders: [DateReminder]
    private var loadFailure: Error?

    init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storageURL = storageURL ?? Self.defaultStorageURL(fileManager: fileManager)
        do {
            reminders = try Self.load(from: self.storageURL, fileManager: fileManager)
        } catch {
            reminders = []
            loadFailure = error
        }
    }

    func allReminders() -> [DateReminder] {
        lock.withLock { reminders }
    }

    func dashboardItems(today: ReminderLocalDate = ReminderLocalDate(Date())) -> [ReminderDashboardItem] {
        ReminderSchedule.dashboardItems(from: allReminders(), today: today)
    }

    func upsert(_ reminder: DateReminder) throws {
        try mutate { reminders in
            if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
                reminders[index] = reminder
            } else {
                reminders.append(reminder)
            }
        }
    }

    func delete(id: UUID) throws {
        try mutate { reminders in
            reminders.removeAll { $0.id == id }
        }
    }

    func complete(id: UUID, on today: ReminderLocalDate = ReminderLocalDate(Date())) throws {
        try mutate { reminders in
            guard let index = reminders.firstIndex(where: { $0.id == id }) else {
                return
            }
            if let updated = ReminderSchedule.completed(reminders[index], on: today) {
                reminders[index] = updated
            } else {
                reminders.remove(at: index)
            }
        }
    }

    private func mutate(_ update: (inout [DateReminder]) -> Void) throws {
        try lock.withLock {
            if let loadFailure {
                throw ReminderStoreError.unreadableFile(storageURL.path, loadFailure.localizedDescription)
            }
            var updated = reminders
            update(&updated)
            try save(updated)
            reminders = updated
        }
    }

    private func save(_ reminders: [DateReminder]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ReminderStoreDocument(version: 1, reminders: reminders))
        try data.write(to: storageURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private static func load(from url: URL, fileManager: FileManager) throws -> [DateReminder] {
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(ReminderStoreDocument.self, from: data)
        guard document.version == 1 else {
            throw ReminderStoreError.unsupportedVersion(document.version)
        }
        return document.reminders
    }

    private static func defaultStorageURL(fileManager: FileManager) -> URL {
        if let override = ProcessInfo.processInfo.environment["LUTOP_REMINDERS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lutop", isDirectory: true)
            .appendingPathComponent("reminders.json")
    }
}

enum ReminderStoreError: LocalizedError {
    case unreadableFile(String, String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(path, reason):
            return "The reminder file at \(path) could not be read. Lutop left it unchanged. \(reason)"
        case let .unsupportedVersion(version):
            return "Reminder file version \(version) is not supported."
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
