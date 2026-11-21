import AppKit
import FudgeCore
import SwiftUI

/// Settings → Calendar (SPEC-092): which calendars My Schedule shows, all of them by default, and how many days
/// ahead it looks.
struct CalendarPage: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let problem = model.settingsProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Section {
                SettingsPopupRow(
                    "Days Ahead",
                    selection: Binding(get: { model.calendarDaysAhead }, set: { model.setCalendarDaysAhead($0) }),
                    options: Schedule.daysAheadChoices.map { ($0, $0 == 1 ? "1 day" : "\($0) days") },
                    help: "How far ahead My Schedule shows events, after today.")
            }
            Section("Calendars") {
                if model.calendarAccess.canRead {
                    if model.calendars.isEmpty {
                        Text("This Mac has no calendars.").foregroundStyle(.secondary)
                    }
                    ForEach(model.calendars) { calendar in
                        Toggle(
                            isOn: Binding(
                                get: { model.isCalendarShown(calendar.id) },
                                set: { model.setCalendarShown($0, id: calendar.id) })
                        ) {
                            HStack(spacing: 6) {
                                Circle().fill(ExtensionColor.color(.string(calendar.color)) ?? .gray)
                                    .frame(width: 10, height: 10)
                                Text(calendar.title)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                } else {
                    CalendarAccessRow(model: model)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadCalendars() }
    }
}

/// Calendar access as Fudge has it, with a button to the Calendars list in System Settings. It never asks: only My
/// Schedule's own run does.
struct CalendarAccessRow: View {
    let model: SettingsModel

    var body: some View {
        LabeledContent {
            Button("Open Privacy Settings") { NSWorkspace.shared.open(ScheduleList.privacySettingsURL) }
        } label: {
            Text("Calendars")
            Text(model.calendarAccess.status)
        }
    }
}
