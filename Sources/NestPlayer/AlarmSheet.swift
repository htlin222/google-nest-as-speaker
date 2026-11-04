import SwiftUI

struct AlarmSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            Label("Alarms", systemImage: "alarm")
                .font(.title2.bold())

            if model.alarms.isEmpty {
                ContentUnavailableView(
                    "No alarms",
                    systemImage: "alarm",
                    description: Text("Start a playlist on \(model.selectedDeviceName) at a set time.")
                )
                .frame(height: 160)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($model.alarms) { $alarm in
                            AlarmRow(alarm: $alarm)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 360)
            }

            if let next = model.nextAlarm() {
                Text("Next: \(next.date.formatted(.dateTime.weekday(.wide).hour().minute())) · \(playlistName(next.alarm.playlistID))")
                    .font(.callout)
                    .foregroundStyle(.tint)
            }
            Text("Nest Player must stay open and this Mac awake. Closing the window quits the app. Alarms start from the first track at the speaker's current volume, and never interrupt something already playing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Add Alarm", systemImage: "plus") { model.addAlarm() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func playlistName(_ id: Playlist.ID) -> String {
        model.library.playlists.first { $0.id == id }?.name ?? "Missing playlist"
    }
}

private struct AlarmRow: View {
    @Environment(PlayerModel.self) private var model
    @Binding var alarm: Alarm

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                alarm.hour = parts.hour ?? alarm.hour
                alarm.minute = parts.minute ?? alarm.minute
            }
        )
    }

    /// Weekdays in the user's locale order, starting at the calendar's first weekday.
    private var orderedWeekdays: [(weekday: Int, symbol: String)] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let weekday = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (weekday, symbols[weekday - 1])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Enabled", isOn: $alarm.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Picker("Playlist", selection: $alarm.playlistID) {
                    if !model.library.playlists.contains(where: { $0.id == alarm.playlistID }) {
                        Text("Missing playlist").tag(alarm.playlistID)
                    }
                    ForEach(model.library.playlists) { playlist in
                        Text(playlist.name).tag(playlist.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Spacer()
                Button(role: .destructive) { model.deleteAlarm(alarm.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete alarm")
            }
            HStack(spacing: 6) {
                ForEach(orderedWeekdays, id: \.weekday) { day in
                    let selected = alarm.weekdays.contains(day.weekday)
                    Button(day.symbol) {
                        if selected { alarm.weekdays.remove(day.weekday) } else { alarm.weekdays.insert(day.weekday) }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 24)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                }
                Text(alarm.weekdays.isEmpty ? "Every day" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .opacity(alarm.isEnabled ? 1 : 0.55)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
