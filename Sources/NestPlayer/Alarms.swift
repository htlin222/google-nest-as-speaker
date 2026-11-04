import Foundation

/// A daily wake-up: at `hour:minute` on the chosen weekdays, play `playlistID` from its first track.
struct Alarm: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    var isEnabled: Bool
    var hour: Int
    var minute: Int
    /// Calendar weekdays (1 = Sunday … 7 = Saturday); empty means every day.
    var weekdays: Set<Int>
    var playlistID: Playlist.ID

    init(id: UUID = UUID(), isEnabled: Bool = true, hour: Int = 7, minute: Int = 0,
         weekdays: Set<Int> = [], playlistID: Playlist.ID) {
        self.id = id
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.playlistID = playlistID
    }

    func runs(onWeekday weekday: Int) -> Bool { weekdays.isEmpty || weekdays.contains(weekday) }
}

enum AlarmSchedule {
    /// Only fire this close to the scheduled time, so a Mac waking hours later stays quiet.
    static let lateWindow: TimeInterval = 120

    /// The scheduled time that should fire now, or nil. `lastFired` prevents firing twice.
    static func dueFire(_ alarm: Alarm, now: Date, lastFired: Date?, calendar: Calendar = .current) -> Date? {
        guard alarm.isEnabled,
              var scheduled = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: now)
        else { return nil }
        if scheduled > now {
            // Just after midnight the relevant occurrence is yesterday's.
            guard let previous = calendar.date(byAdding: .day, value: -1, to: scheduled) else { return nil }
            scheduled = previous
        }
        guard alarm.runs(onWeekday: calendar.component(.weekday, from: scheduled)),
              now.timeIntervalSince(scheduled) < lateWindow,
              lastFired.map({ $0 < scheduled }) ?? true
        else { return nil }
        return scheduled
    }

    /// The next time the alarm will ring after `now`, for display.
    static func nextFire(_ alarm: Alarm, after now: Date, calendar: Calendar = .current) -> Date? {
        guard alarm.isEnabled else { return nil }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let candidate = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: day),
                  candidate > now
            else { continue }
            if alarm.runs(onWeekday: calendar.component(.weekday, from: candidate)) { return candidate }
        }
        return nil
    }
}
