import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    struct State: Equatable {
        var percent: Int
        var isCharging: Bool
        var isCharged: Bool
        var minutesRemaining: Int?
    }

    @Published private(set) var state: State?

    private var timer: DispatchSourceTimer?

    func start() {
        self.refresh()
        // Charge moves in minutes, not milliseconds; a slow poll beats wiring an IOKit run loop source.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        self.timer?.cancel()
        self.timer = nil
    }

    private func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            self.state = nil
            return
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }

            let minutes = info[kIOPSTimeToEmptyKey] as? Int
            let next = State(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: info[kIOPSIsChargedKey] as? Bool ?? false,
                // IOKit reports -1 while it is still estimating.
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
            if next != self.state { self.state = next }
            return
        }

        self.state = nil
    }
}

extension BatteryMonitor.State {
    var symbol: String {
        if self.isCharging || self.isCharged { return "battery.100.bolt" }
        switch self.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    var detail: String? {
        if self.isCharged { return "Cargada" }
        if self.isCharging { return "Cargando" }
        guard let minutesRemaining else { return nil }
        let hours = minutesRemaining / 60
        let minutes = minutesRemaining % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
