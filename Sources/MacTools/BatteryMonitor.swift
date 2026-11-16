import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    enum Event: Equatable {
        case connected
        case disconnected
        case low
        case full
    }

    struct State: Equatable {
        var percent: Int
        var isCharging: Bool
        var isCharged: Bool
        var minutesRemaining: Int?
        var isPluggedIn: Bool = false

        var isLow: Bool { !self.isPluggedIn && self.percent <= 20 }
        var isFull: Bool { self.isPluggedIn && self.percent >= 100 }

    }

    struct EventTracker {
        private var previous: State?
        private var warnedLow = false
        private var warnedFull = false

        mutating func update(_ state: State) -> Event? {
            defer { self.previous = state }
            if state.isPluggedIn {
                self.warnedLow = false
                if state.isFull && !self.warnedFull {
                    self.warnedFull = true
                    return self.previous == nil ? nil : .full
                }
                if self.previous?.isPluggedIn == false { return .connected }
                return nil
            }

            self.warnedFull = false
            // Charge estimates can oscillate near 20%; reconnecting power rearms the warning.
            if state.isLow && !self.warnedLow {
                self.warnedLow = true
                return .low
            }
            if self.previous?.isPluggedIn == true { return .disconnected }
            return nil
        }
    }

    @Published private(set) var state: State?

    private var timer: DispatchSourceTimer?
    private var powerSource: CFRunLoopSource?

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        self.timer?.cancel()
    }

    func start() {
        guard self.powerSource == nil, self.timer == nil else { return }
        self.refresh()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            // This source is registered exclusively on the main run loop.
            MainActor.assumeIsolated { monitor.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source {
            self.powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        self.powerSource = nil
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
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
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
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil,
                isPluggedIn: info[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
            if next != self.state { self.state = next }
            return
        }

        self.state = nil
    }
}

extension BatteryMonitor.State {
    var symbol: String {
        if self.isCharging { return "battery.100.bolt" }
        return self.outlineSymbol
    }

    var outlineSymbol: String {
        switch self.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    var detail: String? {
        if self.isFull { return "Cargada" }
        if self.isCharging { return "Cargando" }
        if self.isPluggedIn { return "Conectado" }
        guard let minutesRemaining else { return nil }
        let hours = minutesRemaining / 60
        let minutes = minutesRemaining % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
