import AppKit
import Combine
import Foundation

extension Store.Filter: CaseIterable, Identifiable {
    static var allCases: [Store.Filter] { [.all, .dictations, .favorites, .images] }
    var id: String { self.label }

    var label: String {
        switch self {
        case .all: return "Todo"
        case .dictations: return "Dictados"
        case .favorites: return "Favoritos"
        case .images: return "Fotos"
        }
    }
}

@MainActor
final class HistoryModel: ObservableObject {
    @Published var query = "" { didSet { self.reload() } }
    @Published var filter: Store.Filter = .all { didSet { self.reload() } }
    @Published private(set) var items: [ClipItem] = []
    @Published var selection = 0
    @Published var dictationWarning = false
    @Published private(set) var justCopiedID: Int64?
    @Published var previewing = false

    func togglePreview() {
        guard self.selectedItem != nil else { return }
        self.previewing.toggle()
    }

    private var flashTask: Task<Void, Never>?

    func flashCopied(_ id: Int64) {
        self.justCopiedID = id
        self.flashTask?.cancel()
        self.flashTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self.justCopiedID = nil
        }
    }

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        self.items.indices.contains(self.selection) ? self.items[self.selection] : nil
    }

    func reload() {
        let previous = self.selectedItem?.id
        self.items = self.store.items(query: self.query, filter: self.filter)
        if let previous, let index = items.firstIndex(where: { $0.id == previous }) {
            self.selection = index
        } else {
            self.selection = self.items.isEmpty ? 0 : min(self.selection, self.items.count - 1)
        }
    }

    func reset() {
        self.query = ""
        self.filter = .all
        self.selection = 0
        self.previewing = false
        self.reload()
    }

    /// Reflects FluidVoice's own history switch; polled so the banner appears even when nothing is ingested.
    func refreshDictationWarning(_ disabled: Bool) {
        guard self.dictationWarning != disabled else { return }
        self.dictationWarning = disabled
    }

    func move(by delta: Int) {
        guard !self.items.isEmpty else { return }
        self.selection = max(0, min(self.items.count - 1, self.selection + delta))
    }

    func togglePin() {
        guard let item = selectedItem else { return }
        self.togglePin(item)
    }

    func toggleFavorite() {
        guard let item = selectedItem else { return }
        self.toggleFavorite(item)
    }

    func togglePin(_ item: ClipItem) {
        self.store.setPinned(!item.pinned, id: item.id)
        self.reload()
    }

    func toggleFavorite(_ item: ClipItem) {
        self.store.setFavorite(!item.favorite, id: item.id)
        self.reload()
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        self.delete(item)
    }

    func delete(_ item: ClipItem) {
        self.store.delete(id: item.id)
        self.reload()
    }

    func rename(_ item: ClipItem) {
        let alert = NSAlert()
        alert.messageText = "Título"
        alert.informativeText = "Un nombre para reconocerla después. Vacío vuelve al automático."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.title ?? ""
        field.placeholderString = "Ej: logo del cliente"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.store.setTitle(field.stringValue, id: item.id)
        self.reload()
    }

    func clearAll() {
        let total = self.store.counts().total
        let alert = NSAlert()
        alert.messageText = "¿Borrar todo el historial?"
        alert.informativeText = "Se eliminan \(total) items y todas las imágenes guardadas, incluidos los fijados. No se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Borrar todo")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.store.deleteAll()
        self.reload()
    }

    func stats() -> String {
        let counts = self.store.counts()
        let bytes = ByteCountFormatter.string(fromByteCount: counts.imageBytes, countStyle: .file)
        return "\(counts.total) items · \(counts.images) imágenes · \(bytes)"
    }
}
