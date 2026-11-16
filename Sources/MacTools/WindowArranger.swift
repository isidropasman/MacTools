import AppKit
import ApplicationServices
import Combine

enum WindowLayout: String, CaseIterable, Identifiable, Sendable {
    case grid
    case columns
    case rows

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .grid: "Cuadrícula"
        case .columns: "Columnas"
        case .rows: "Filas"
        }
    }
}

@MainActor
final class WindowArranger {
    private struct ScanResult {
        let identifiers: Set<String>
    }

    private struct VisibleWindow {
        let processID: pid_t
        let identifier: String
        let bounds: CGRect
    }

    private struct ManagedWindow {
        let element: AXUIElement
    }

    private let queue = DispatchQueue(label: "com.zent.mactools.window-arranger")
    private var timer: DispatchSourceTimer?
    private var lastWindowIDs: Set<String>?
    private var cancellables = Set<AnyCancellable>()
    private var isScanning = false
    private var scanAgain = false
    private var forceNextScan = false

    func start() {
        Settings.shared.$autoArrangeWindows
            .removeDuplicates()
            .sink { [weak self] enabled in self?.setEnabled(enabled) }
            .store(in: &self.cancellables)

        Settings.shared.$windowLayout
            .dropFirst()
            .sink { [weak self] _ in self?.scan(force: true) }
            .store(in: &self.cancellables)

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ] {
            workspaceNotifications.publisher(for: name)
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.scan() }
                .store(in: &self.cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scan(force: true) }
            .store(in: &self.cancellables)
    }

    private func setEnabled(_ enabled: Bool) {
        self.timer?.cancel()
        self.timer = nil
        guard enabled else { return }

        self.lastWindowIDs = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(350))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
        self.scan(force: true)
    }

    private func scan(force: Bool = false) {
        guard Settings.shared.autoArrangeWindows, Paster.isTrusted else { return }
        if self.isScanning {
            self.scanAgain = true
            self.forceNextScan = self.forceNextScan || force
            return
        }

        self.isScanning = true
        let layout = Settings.shared.windowLayout
        let previousIDs = self.lastWindowIDs
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let mainScreenTop = NSScreen.main?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0
        self.queue.async { [weak self] in
            let result = Self.arrangeWindows(
                force: force,
                previousIDs: previousIDs,
                layout: layout,
                visibleFrames: visibleFrames,
                mainScreenTop: mainScreenTop
            )
            Task { @MainActor [weak self] in self?.finishScan(result) }
        }
    }

    private func finishScan(_ result: ScanResult?) {
        if let result { self.lastWindowIDs = result.identifiers }
        self.isScanning = false
        guard self.scanAgain else { return }
        let force = self.forceNextScan
        self.scanAgain = false
        self.forceNextScan = false
        self.scan(force: force)
    }

    private nonisolated static func arrangeWindows(
        force: Bool,
        previousIDs: Set<String>?,
        layout: WindowLayout,
        visibleFrames: [CGRect],
        mainScreenTop: CGFloat
    ) -> ScanResult? {
        guard Settings.autoArrangeWindowsNow,
              AXIsProcessTrusted(),
              let visible = self.visibleStandardWindowFrames()
        else { return nil }

        let identifiers = Set(visible.map(\.identifier))
        guard force || identifiers != previousIDs else { return ScanResult(identifiers: identifiers) }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        var screenWindows: [Int: [ManagedWindow]] = [:]
        var matchedIdentifiers = Set<String>()
        var processedProcessIDs = Set<pid_t>()

        for candidate in visible {
            let processID = candidate.processID
            guard processID != ownProcessID, processedProcessIDs.insert(processID).inserted else { continue }
            let app = AXUIElementCreateApplication(processID)
            guard let rawWindows = self.attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let appWindows = visible.filter { $0.processID == processID }

            for candidate in appWindows {
                guard !matchedIdentifiers.contains(candidate.identifier) else { continue }
                for window in rawWindows {
                    guard self.isStandardWindow(window),
                          let frame = self.frame(of: window),
                          self.overlap(frame, candidate.bounds) >= 0.9
                    else { continue }

                    matchedIdentifiers.insert(candidate.identifier)
                    let cocoaFrame = CGRect(
                        x: frame.minX,
                        y: mainScreenTop - frame.maxY,
                        width: frame.width,
                        height: frame.height
                    )
                    guard let screenIndex = self.screenIndex(for: cocoaFrame, in: visibleFrames) else { break }
                    screenWindows[screenIndex, default: []].append(ManagedWindow(element: window))
                    break
                }
            }
        }

        guard Settings.autoArrangeWindowsNow else { return ScanResult(identifiers: identifiers) }
        for (screenIndex, windows) in screenWindows {
            guard visibleFrames.indices.contains(screenIndex) else { continue }
            let tiles = self.tiles(in: visibleFrames[screenIndex], count: windows.count, layout: layout)
            for (window, tile) in zip(windows, tiles) {
                self.move(window, to: tile, mainScreenTop: mainScreenTop)
            }
        }

        return ScanResult(identifiers: identifiers)
    }

    private nonisolated static func visibleStandardWindowFrames() -> [VisibleWindow]? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return windowList.compactMap { item in
            guard let processID = item[kCGWindowOwnerPID as String] as? Int32,
                  processID != ownProcessID,
                  let number = item[kCGWindowNumber as String] as? Int,
                  let layer = item[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let rawBounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  bounds.width >= 180,
                  bounds.height >= 120
            else { return nil }
            return VisibleWindow(
                processID: processID,
                identifier: "\(processID):\(number)",
                bounds: bounds
            )
        }
    }

    private nonisolated static func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard self.attribute(window, kAXSubroleAttribute as String) as? String == kAXStandardWindowSubrole as String,
              self.attribute(window, kAXMinimizedAttribute as String) as? Bool != true
        else { return false }
        return true
    }

    private nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        guard let rawPositionValue = self.attribute(window, kAXPositionAttribute as String),
              CFGetTypeID(rawPositionValue) == AXValueGetTypeID(),
              let rawSizeValue = self.attribute(window, kAXSizeAttribute as String),
              CFGetTypeID(rawSizeValue) == AXValueGetTypeID()
        else { return nil }

        let positionValue = unsafeBitCast(rawPositionValue, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSizeValue, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width >= 180,
              size.height >= 120
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let area = lhs.width * lhs.height
        guard area > 0 else { return 0 }
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height / area
    }

    private nonisolated static func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int? {
        let candidate = screens.enumerated().max { lhs, rhs in
            self.intersectionArea(frame, lhs.element) < self.intersectionArea(frame, rhs.element)
        }
        guard let candidate, self.intersectionArea(frame, candidate.element) > 0 else { return nil }
        return candidate.offset
    }

    private nonisolated static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private nonisolated static func tiles(in frame: CGRect, count: Int, layout: WindowLayout) -> [CGRect] {
        guard count > 0 else { return [] }
        let spacing: CGFloat = 8
        let columns: Int
        let rows: Int
        switch layout {
        case .grid:
            columns = Int(ceil(sqrt(Double(count))))
            rows = Int(ceil(Double(count) / Double(columns)))
        case .columns:
            columns = count
            rows = 1
        case .rows:
            columns = 1
            rows = count
        }

        let width = (frame.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let height = (frame.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
        return (0 ..< count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(
                x: frame.minX + spacing + CGFloat(column) * (width + spacing),
                y: frame.maxY - spacing - height - CGFloat(row) * (height + spacing),
                width: width,
                height: height
            ).integral
        }
    }

    private nonisolated static func move(_ window: ManagedWindow, to frame: CGRect, mainScreenTop: CGFloat) {
        var size = frame.size
        var origin = CGPoint(x: frame.minX, y: mainScreenTop - frame.maxY)
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &origin)
        else { return }

        _ = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
    }
}
