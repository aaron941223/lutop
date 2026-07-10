// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import Lutop

private var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

@Test
func monthlyReminderKeepsPreferredDayAcrossShortMonth() {
    var reminder = DateReminder(
        title: "Month end",
        anchorDate: localDate(2026, 1, 31),
        recurrence: .monthly,
        warningDays: 7,
        completedThrough: localDate(2026, 1, 31)
    )

    #expect(ReminderSchedule.nextDueDate(for: reminder, calendar: testCalendar) == localDate(2026, 2, 28))
    reminder.completedThrough = localDate(2026, 2, 28)
    #expect(ReminderSchedule.nextDueDate(for: reminder, calendar: testCalendar) == localDate(2026, 3, 31))
}

@Test
func yearlyLeapDayUsesLastDayOfFebruary() {
    var reminder = DateReminder(
        title: "Leap day",
        anchorDate: localDate(2024, 2, 29),
        recurrence: .yearly,
        warningDays: 14,
        completedThrough: localDate(2024, 2, 29)
    )

    #expect(ReminderSchedule.nextDueDate(for: reminder, calendar: testCalendar) == localDate(2025, 2, 28))
    reminder.completedThrough = localDate(2027, 2, 28)
    #expect(ReminderSchedule.nextDueDate(for: reminder, calendar: testCalendar) == localDate(2028, 2, 29))
}

@Test
func weeklyReminderKeepsItsAnchorWeekday() {
    let reminder = DateReminder(
        title: "Weekly review",
        anchorDate: localDate(2026, 7, 6),
        recurrence: .weekly,
        warningDays: 1,
        completedThrough: localDate(2026, 7, 10)
    )

    #expect(ReminderSchedule.nextDueDate(for: reminder, calendar: testCalendar) == localDate(2026, 7, 13))
}

@Test
func completingOverdueRecurringReminderSkipsToFutureOccurrence() {
    let reminder = DateReminder(
        title: "Salary",
        anchorDate: localDate(2026, 1, 5),
        recurrence: .monthly,
        warningDays: 3
    )
    let completed = ReminderSchedule.completed(reminder, on: localDate(2026, 7, 10))

    #expect(completed != nil)
    #expect(completed.flatMap { ReminderSchedule.nextDueDate(for: $0, calendar: testCalendar) } == localDate(2026, 8, 5))
}

@Test
func urgencyAndDueDateControlSorting() {
    let today = localDate(2026, 7, 10)
    let reminders = [
        DateReminder(title: "Later", anchorDate: localDate(2026, 8, 1), recurrence: .none, warningDays: 7),
        DateReminder(title: "Warning", anchorDate: localDate(2026, 7, 13), recurrence: .none, warningDays: 7),
        DateReminder(title: "Today", anchorDate: today, recurrence: .none, warningDays: 1),
        DateReminder(title: "Overdue", anchorDate: localDate(2026, 7, 8), recurrence: .none, warningDays: 1)
    ]

    let items = ReminderSchedule.dashboardItems(from: reminders, today: today, calendar: testCalendar)
    #expect(items.map(\.reminder.title) == ["Overdue", "Today", "Warning", "Later"])
    #expect(items.map(\.urgency) == [.due, .due, .warning, .normal])
}

@Test
func storeRoundTripAndCompletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("reminders.json")
    let store = ReminderStore(storageURL: url)
    let oneTime = DateReminder(
        title: "Subscription",
        anchorDate: localDate(2026, 8, 7),
        recurrence: .none,
        warningDays: 14
    )
    let recurring = DateReminder(
        title: "Salary",
        anchorDate: localDate(2026, 7, 5),
        recurrence: .monthly,
        warningDays: 3
    )

    try store.upsert(oneTime)
    try store.upsert(recurring)
    try store.complete(id: oneTime.id, on: localDate(2026, 8, 7))
    try store.complete(id: recurring.id, on: localDate(2026, 7, 10))

    let reloaded = ReminderStore(storageURL: url)
    #expect(reloaded.allReminders().count == 1)
    #expect(reloaded.allReminders().first?.id == recurring.id)
    #expect(
        reloaded.allReminders().first.flatMap {
            ReminderSchedule.nextDueDate(for: $0, calendar: testCalendar)
        } == localDate(2026, 8, 5)
    )
}

@Test
func unreadableStoreIsNotOverwritten() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("reminders.json")
    let original = Data("not-json".utf8)
    try original.write(to: url)
    let store = ReminderStore(storageURL: url)

    var didThrow = false
    do {
        try store.upsert(DateReminder(
            title: "Must not overwrite",
            anchorDate: localDate(2026, 7, 10),
            recurrence: .none,
            warningDays: 3
        ))
    } catch {
        didThrow = true
    }

    #expect(didThrow)
    #expect(try Data(contentsOf: url) == original)
}

private func localDate(_ year: Int, _ month: Int, _ day: Int) -> ReminderLocalDate {
    ReminderLocalDate(year: year, month: month, day: day)
}
