import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The catalogue as a table: the token syntax is fast once you know it, but reorganising projects
/// by retyping "#plexo/code" on every task is not editing, it is data entry.
struct ProjectsView: View {
    @ObservedObject var tasks: TaskStore
    let onClose: () -> Void

    @State private var newProject = ""
    /// Hand-rolled instead of DisclosureGroup: nesting a colour menu inside its label made the
    /// triangle swallow clicks meant for the menu and vice versa.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // The field lines up with the cards below it: same gutter, same inner padding.
            HStack(spacing: 8) {
                TextField("Nuevo proyecto", text: self.$newProject)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
                    .onSubmit(self.addProject)
                Button("Agregar", action: self.addProject)
                    .buttonStyle(.bordered)
                    .disabled(TaskStore.normalize(self.newProject).isEmpty)
            }
            .padding(14)

            Divider()

            if self.tasks.projects.isEmpty {
                Text("Sin proyectos todavía")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
            } else {
                // Grows with the list instead of leaving half a window of grey below three rows,
                // and stops growing before it runs off the screen.
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(self.tasks.projects, id: \.self) { project in
                            self.projectCard(project)
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 420)
                .scrollBounceBehavior(.basedOnSize)
            }

            Divider()

            HStack {
                Button(action: self.onClose) {
                    Label("Volver", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Listo", action: self.onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
    }

    private func projectCard(_ project: String) -> some View {
        let color = self.tasks.color(of: project)
        let isOpen = self.expanded.contains(project)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if isOpen { self.expanded.remove(project) } else { self.expanded.insert(project) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                ProjectBadge(
                    symbol: self.tasks.symbol(of: project),
                    logo: self.tasks.logo(of: project),
                    color: color,
                    pickColor: { self.tasks.setColor($0, for: project) },
                    pickSymbol: { self.tasks.setSymbol($0, for: project) },
                    pickLogo: { self.tasks.setLogo(from: $0, for: project) },
                    clearLogo: { self.tasks.removeLogo(for: project) }
                )

                EditableName(name: project, bold: true) { self.tasks.renameProject(project, to: $0) }

                Spacer()

                self.count(self.tasks.taskCount(project: project))

                Button {
                    self.tasks.removeProject(project)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Las tareas no se borran, quedan sin proyecto")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())

            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(self.tasks.sections(of: project), id: \.self) { section in
                        HStack(spacing: 8) {
                            Circle().fill(color.opacity(0.55)).frame(width: 5, height: 5)
                            EditableName(name: section) { self.tasks.renameSection(section, to: $0, in: project) }
                            Spacer()
                            self.count(self.tasks.taskCount(project: project, section: section))
                            Button {
                                self.tasks.removeSection(section, from: project)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    NewSectionField { self.tasks.addSection($0, to: project) }
                }
                .padding(.leading, 34)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOpen)
    }

    private func count(_ value: Int) -> some View {
        Text(value == 0 ? "" : "\(value)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(value == 0 ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary)))
    }

    private func addProject() {
        self.tasks.addProject(self.newProject)
        self.newProject = ""
    }
}

/// A Menu whose label is a bare Circle collapsed to nothing, so the colour was unreachable. An
/// explicit swatch with a palette popover says what it does without a hover.
private struct ProjectBadge: View {
    let symbol: String
    let logo: NSImage?
    let color: Color
    let pickColor: (String?) -> Void
    let pickSymbol: (String?) -> Void
    let pickLogo: (URL) -> Bool
    let clearLogo: () -> Void

    @State private var showing = false
    @State private var failed = false

    var body: some View {
        Button { self.showing = true } label: {
            Group {
                if let logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    Image(systemName: self.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.logo == nil ? AnyShapeStyle(self.color.gradient) : AnyShapeStyle(.quaternary))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Logo y color del proyecto")
        .popover(isPresented: self.$showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(ProjectPalette.order, id: \.self) { name in
                        Button { self.pickColor(name) } label: {
                            Circle()
                                .fill(ProjectPalette.colors[name] ?? .blue)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(name.capitalized)
                    }
                    Button("Auto") { self.pickColor(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    Text("Imagen").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Elegir…", action: self.chooseFile)
                        .controlSize(.small)
                    if self.logo != nil {
                        Button("Quitar") { self.clearLogo() }
                            .controlSize(.small)
                    }
                }
                if self.failed {
                    Text("No pude leer esa imagen. PNG, JPG, TIFF, HEIC y PDF andan; SVG no lo abre macOS.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Arrastrá una imagen acá o elegí un archivo. Reemplaza al símbolo.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider()

                Text("Símbolo").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 10), spacing: 6) {
                    ForEach(ProjectSymbols.all, id: \.self) { name in
                        Button { self.pickSymbol(name) } label: {
                            Image(systemName: name)
                                .font(.system(size: 12))
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(name == self.symbol ? AnyShapeStyle(self.color.opacity(0.35)) : AnyShapeStyle(.quaternary))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 314)
            }
            .padding(14)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.failed = !self.pickLogo(url) }
                }
                return true
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.prompt = "Usar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.failed = !self.pickLogo(url)
    }
}

/// Renaming in place beats a modal for a one-word change.
private struct EditableName: View {
    let name: String
    var bold = false
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        Group {
            if self.editing {
                TextField("", text: self.$draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
                    .frame(maxWidth: 180)
                    .onSubmit {
                        self.commit(self.draft)
                        self.editing = false
                    }
            } else {
                Text(self.name)
                    .fontWeight(self.bold ? .semibold : .regular)
                    .onTapGesture(count: 2) {
                        self.draft = self.name
                        self.editing = true
                    }
                    .help("Doble clic para renombrar")
            }
        }
    }
}

private struct NewSectionField: View {
    let add: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 9)).foregroundStyle(.tertiary)
            TextField("Nueva sección", text: self.$draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    self.add(self.draft)
                    self.draft = ""
                }
        }
    }
}
