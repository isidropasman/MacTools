import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var searchFocused: Bool
    let onPick: (ClipItem) -> Void
    let onCopy: (ClipItem) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            if self.model.items.isEmpty {
                self.emptyState
            } else {
                self.list
            }
            Divider()
            self.footer
        }
        .frame(minWidth: PanelController.width, minHeight: 460)
        .background(.ultraThinMaterial)
        .overlay { if self.model.previewing, let item = model.selectedItem { self.preview(item) } }
        .onAppear { self.searchFocused = true }
    }

    // MARK: - Header

    /// Search on top, scope bar underneath: the same split Finder uses.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
                TextField("Buscar", text: self.$model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused(self.$searchFocused)
                if !self.model.query.isEmpty {
                    Button { self.model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Limpiar")
                }
                Button(action: self.model.clearAll) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Borrar todo el historial")

                Button(action: self.onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Configuración (⌘,)")
            }

            Picker("Filtro", selection: self.$model.filter) {
                ForEach(Store.Filter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        // Vertical room for the traffic lights, which sit over the full-size content view.
        .padding(.top, 32)
        .padding(.bottom, 10)
    }

    // MARK: - Body

    private var emptyState: some View {
        Group {
            if self.model.query.isEmpty {
                ContentUnavailableView(
                    "Todavía no copiaste nada",
                    systemImage: "doc.on.clipboard",
                    description: Text("Lo que copies aparece acá automáticamente.")
                )
            } else {
                ContentUnavailableView.search(text: self.model.query)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(self.model.items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(
                            item: item,
                            selected: index == self.model.selection,
                            copied: self.model.justCopiedID == item.id,
                            onCopy: { self.onCopy(item) },
                            onRename: { self.model.rename(item) },
                            onTogglePin: { self.model.togglePin(item) },
                            onToggleFavorite: { self.model.toggleFavorite(item) }
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            self.model.selection = index
                            // A thumbnail says nothing about what the image is, so a click looks
                            // before it copies. Text is legible in the row already.
                            if item.kind == .image {
                                self.model.previewing = true
                            } else {
                                self.onPick(item)
                            }
                        }
                        .contextMenu {
                            Button("Copiar") { self.onCopy(item) }
                            Button(item.favorite ? "Quitar de favoritos" : "Marcar favorito") {
                                self.model.toggleFavorite(item)
                            }
                            Button(item.pinned ? "Dejar de fijar" : "Fijar arriba") {
                                self.model.togglePin(item)
                            }
                            if item.kind == .image {
                                Button("Cambiar título…") { self.model.rename(item) }
                            }
                            Divider()
                            Button("Eliminar", role: .destructive) { self.model.delete(item) }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: self.model.selection) { _, new in
                guard self.model.items.indices.contains(new) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(self.model.items[new].id, anchor: .center)
                }
            }
        }
    }

    private func preview(_ item: ClipItem) -> some View {
        ZStack {
            // Only the backdrop dismisses, so clicking the buttons does not close the preview first.
            Rectangle()
                .fill(.ultraThickMaterial)
                .onTapGesture { self.model.previewing = false }

            VStack(spacing: 14) {
                if item.kind == .image, let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ScrollView {
                        Text(item.text ?? "")
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        self.onCopy(item)
                    } label: {
                        Label("Copiar", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cerrar") { self.model.previewing = false }
                        .buttonStyle(.bordered)

                    Text("espacio o esc")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if self.model.dictationWarning {
                Label("FluidVoice tiene el historial apagado", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            Text(self.model.stats())
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            self.shortcut("↩", "pegar")
            self.shortcut("⌘1", "ir")
            self.shortcut("espacio", "ver")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HistoryRow: View {
    let item: ClipItem
    let selected: Bool
    let copied: Bool
    let onCopy: () -> Void
    let onRename: () -> Void
    let onTogglePin: () -> Void
    let onToggleFavorite: () -> Void
    @State private var hovered = false
    @State private var expanded = false
    @State private var expandTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 10) {
            self.icon
            VStack(alignment: .leading, spacing: 2) {
                // Hovering expands the row instead of raising a tooltip: the tap layer above the row
                // covers its tracking area, so the native tooltip never fires. Capped so a long
                // dictation cannot push the whole list around.
                Text(self.item.kind == .text ? (self.item.text ?? self.item.preview) : self.item.preview)
                    .lineLimit(self.expanded ? 12 : 2)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if self.item.source == .fluidvoice {
                        Label("Dictado", systemImage: "mic.fill")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    if let app = item.sourceApp {
                        Text(app).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(self.item.age)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            self.actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Apple insets list selection from the container edges instead of bleeding to them.
        // `.selection` renders unemphasised grey outside a real List, so use the focused-list colour.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(self.selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        )
        .foregroundStyle(self.selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { self.hovered = hovering }

            // The row grows only after a deliberate pause; expanding on contact makes the list
            // jump around while the pointer is just travelling across it.
            self.expandTask?.cancel()
            guard hovering else {
                withAnimation(.easeOut(duration: 0.12)) { self.expanded = false }
                return
            }
            self.expandTask = Task {
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) { self.expanded = true }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            self.iconButton(
                on: self.item.favorite,
                onSymbol: "star.fill", offSymbol: "star",
                tint: AnyShapeStyle(Color.yellow), help: "Favorito (⌘D)", action: self.onToggleFavorite
            )
            self.iconButton(
                on: self.item.pinned,
                onSymbol: "pin.fill", offSymbol: "pin",
                tint: AnyShapeStyle(Color.orange), help: "Fijar arriba (⌘P)", action: self.onTogglePin
            )
            if self.item.kind == .image {
                self.iconButton(
                    on: self.item.title != nil,
                    onSymbol: "pencil.circle.fill", offSymbol: "pencil",
                    tint: AnyShapeStyle(.secondary), help: "Poner un título", action: self.onRename
                )
            }
            self.copyButton
        }
    }

    /// Always rendered so the row keeps a stable width; dimmed until hovered or selected.
    private func iconButton(
        on: Bool,
        onSymbol: String,
        offSymbol: String,
        tint: AnyShapeStyle,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: on ? onSymbol : offSymbol)
                .imageScale(.medium)
                .foregroundStyle(on ? tint : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(on || self.hovered || self.selected ? 1 : 0)
        .help(help)
    }

    private var copyButton: some View {
        Button(action: self.onCopy) {
            Image(systemName: self.copied ? "checkmark.circle.fill" : "doc.on.doc")
                .imageScale(.medium)
                .foregroundStyle(self.copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(self.copied || self.hovered || self.selected ? 1 : 0)
        .scaleEffect(self.copied ? 1.25 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.45), value: self.copied)
        .help("Copiar")
    }

    @ViewBuilder
    private var icon: some View {
        if self.item.kind == .image, let thumb = item.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 38, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        } else {
            Image(systemName: self.item.kind == .image ? "photo" : "text.alignleft")
                .imageScale(.medium)
                .frame(width: 38, height: 28)
                .foregroundStyle(.secondary)
        }
    }
}
