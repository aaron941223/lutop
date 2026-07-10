// SPDX-License-Identifier: GPL-3.0-only

import AppKit

@MainActor
enum ReminderEditor {
    static func present(existing: DateReminder? = nil) -> DateReminder? {
        let form = ReminderEditorForm(reminder: existing)
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Date Reminder" : "Edit Date Reminder"
        alert.informativeText = "Dates use the current macOS calendar and time zone."
        alert.alertStyle = .informational
        alert.accessoryView = form
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isEnabled = form.isValid
        form.validityChanged = { [weak alert] isValid in
            alert?.buttons.first?.isEnabled = isValid
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return form.reminder(existing: existing)
    }
}

@MainActor
private final class ReminderEditorForm: NSView, NSTextFieldDelegate {
    private static let warningOptions = [1, 3, 7, 14, 30]

    private let titleField = NSTextField(string: "")
    private let datePicker = NSDatePicker(frame: .zero)
    private let recurrencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let warningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var validityChanged: ((Bool) -> Void)?

    var isValid: Bool {
        !normalizedTitle.isEmpty
    }

    private var normalizedTitle: String {
        titleField.stringValue
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(reminder: DateReminder?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 132))

        let labels = ["Title", "Date", "Repeat", "Warn before"]
        let yPositions: [CGFloat] = [104, 72, 40, 8]
        for (labelText, y) in zip(labels, yPositions) {
            let label = NSTextField(labelWithString: labelText)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y + 2, width: 82, height: 22)
            addSubview(label)
        }

        titleField.placeholderString = "Reminder title"
        titleField.delegate = self
        titleField.frame = NSRect(x: 92, y: 104, width: 268, height: 24)
        addSubview(titleField)

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.frame = NSRect(x: 92, y: 72, width: 168, height: 24)
        addSubview(datePicker)

        recurrencePopup.addItems(withTitles: ReminderRecurrence.allCases.map(\.displayName))
        recurrencePopup.frame = NSRect(x: 92, y: 40, width: 168, height: 26)
        addSubview(recurrencePopup)

        warningPopup.addItems(withTitles: Self.warningOptions.map { $0 == 1 ? "1 day" : "\($0) days" })
        warningPopup.frame = NSRect(x: 92, y: 8, width: 168, height: 26)
        addSubview(warningPopup)

        if let reminder {
            titleField.stringValue = reminder.title
            datePicker.dateValue = reminder.anchorDate.date() ?? Date()
            recurrencePopup.selectItem(at: ReminderRecurrence.allCases.firstIndex(of: reminder.recurrence) ?? 0)
            warningPopup.selectItem(at: Self.warningOptions.firstIndex(of: reminder.warningDays) ?? 2)
        } else {
            datePicker.dateValue = Date()
            recurrencePopup.selectItem(at: 0)
            warningPopup.selectItem(at: 1)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func controlTextDidChange(_ notification: Notification) {
        validityChanged?(isValid)
    }

    func reminder(existing: DateReminder?) -> DateReminder {
        let anchorDate = ReminderLocalDate(datePicker.dateValue)
        let recurrence = ReminderRecurrence.allCases[max(0, recurrencePopup.indexOfSelectedItem)]
        let warningDays = Self.warningOptions[max(0, warningPopup.indexOfSelectedItem)]
        let preserveCompletion = existing?.anchorDate == anchorDate && existing?.recurrence == recurrence
        return DateReminder(
            id: existing?.id ?? UUID(),
            title: normalizedTitle,
            anchorDate: anchorDate,
            recurrence: recurrence,
            warningDays: warningDays,
            completedThrough: preserveCompletion ? existing?.completedThrough : nil
        )
    }
}
