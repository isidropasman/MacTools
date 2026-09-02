import AppKit
import Combine
import EventKit

@MainActor
final class CalendarManager: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: NSColor
        let isNow: Bool
        /// One entry per account holding this event. Being invited on two accounts is one meeting.
        let accounts: [String]
        let meeting: MeetingLink.Match?

        /// The window where joining is what you actually want to do.
        var isJoinable: Bool {
            guard self.meeting != nil, !self.isAllDay else { return false }
            if self.isNow { return true }
            let minutes = self.start.timeIntervalSinceNow / 60
            return minutes >= 0 && minutes <= 10
        }

        var timeLabel: String {
            if self.isAllDay { return "Todo el día" }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "\(formatter.string(from: self.start)) – \(formatter.string(from: self.end))"
        }

        /// Only for what is coming up; a running meeting already says "ahora".
        var countdown: String? {
            guard !self.isNow, !self.isAllDay else { return nil }
            let minutes = Int(self.start.timeIntervalSinceNow / 60)
            guard minutes >= 0 else { return nil }
            if minutes < 60 { return "en \(minutes) min" }
            return "en \(minutes / 60) h"
        }
    }

    enum Access {
        case unknown
        case granted
        case denied
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var access: Access = .unknown

    struct Account: Identifiable, Equatable {
        let id: String
        let sourceTitle: String
        let calendarTitles: [String]
        var label: String { AccountLabels.label(sourceID: self.id, sourceTitle: self.sourceTitle, calendarTitles: self.calendarTitles) }
    }

    @Published private(set) var accounts: [Account] = []

    private let store = EKEventStore()
    private var timer: DispatchSourceTimer?

    func start() {
        self.refreshAccess()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.reload() }
        timer.resume()
        self.timer = timer

        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: self.store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    func requestAccess() {
        self.store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                self?.access = granted ? .granted : .denied
                if granted { self?.reload() }
            }
        }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            self.access = .granted
            self.reload()
        case .denied, .restricted:
            self.access = .denied
        default:
            self.access = .unknown
        }
    }

    /// Today only, from now on. A past meeting in the notch is noise.
    private func reload() {
        guard self.access == .granted else { return }

        let calendar = Calendar.current
        let now = Date()
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now

        let predicate = self.store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let raw = self.store.events(matching: predicate)
            .filter { !$0.isAllDay || calendar.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }

        self.accounts = self.store.sources.compactMap { source in
            let cals = source.calendars(for: .event)
            guard !cals.isEmpty else { return nil }
            return Account(id: source.sourceIdentifier, sourceTitle: source.title, calendarTitles: cals.map(\.title))
        }
        let labelBySource = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.id, $0.label) })

        // The same meeting invited to two accounts is one row carrying both labels, not two rows.
        var merged: [String: Event] = [:]
        var order: [String] = []

        for event in raw {
            let minute = Int(event.startDate.timeIntervalSince1970 / 60)
            let title = (event.title ?? "Sin título").trimmingCharacters(in: .whitespaces)
            let key = "\(title.lowercased())|\(minute)"
            let account = labelBySource[event.calendar?.source?.sourceIdentifier ?? ""] ?? ""

            if let existing = merged[key] {
                guard !existing.accounts.contains(account), !account.isEmpty else { continue }
                merged[key] = Event(
                    id: existing.id,
                    title: existing.title,
                    start: existing.start,
                    end: existing.end,
                    isAllDay: existing.isAllDay,
                    color: existing.color,
                    isNow: existing.isNow,
                    accounts: existing.accounts + [account],
                    meeting: existing.meeting
                )
            } else {
                order.append(key)
                merged[key] = Event(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: title,
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: event.calendar?.color ?? .systemBlue,
                    isNow: event.startDate <= now && event.endDate >= now,
                    accounts: account.isEmpty ? [] : [account],
                    meeting: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
                )
            }
        }

        let next = order.prefix(6).compactMap { merged[$0] }
        let list = Array(next)
        if list != self.events { self.events = list }
    }
}
