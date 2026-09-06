import AppKit
import SwiftUI

/// Changing it here is the first thing someone does, so it sits on the first screen.
struct LanguagePicker: View {
    @ObservedObject private var settings = Settings.shared
    @State private var relaunchNeeded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Picker("Idioma", selection: Binding(
                get: { self.settings.language },
                set: {
                    self.settings.language = $0
                    self.relaunchNeeded = true
                }
            )) {
                Text("Español").tag("es")
                Text("English").tag("en")
                Divider()
                Text("El del sistema").tag("")
            }
            .labelsHidden()
            .frame(width: 150)

            if self.relaunchNeeded {
                Button("Reiniciar para aplicar", action: Self.relaunch)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// AppleLanguages is read once at launch; there is no way to swap it live.
    static func relaunch() {
        guard let path = Bundle.main.bundlePath as String? else { return }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// First run, and reachable afterwards from the menu. Two things someone new needs: what the app
/// does, and the permissions it cannot grant itself.
struct WelcomeView: View {
    @ObservedObject var setup: Setup
    let onFinish: () -> Void

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if self.page == 0 { self.intro } else { self.checklist }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if self.page == 1 {
                    Button("Atrás") { withAnimation { self.page = 0 } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if self.page == 0 {
                    Button("Empezar") { withAnimation { self.page = 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(self.setup.isReady ? "Listo" : "Seguir igual", action: self.onFinish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .background(.ultraThinMaterial)
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacTools")
                            .font(.system(size: 26, weight: .bold))
                        Text("Todo lo que usás todo el día, colgado de la notch.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    LanguagePicker()
                }

                VStack(spacing: 12) {
                    self.feature(
                        "doc.on.clipboard", "Portapapeles",
                        "Todo lo que copiaste, con búsqueda, fijados y favoritos.",
                        Settings.shared.shortcut(for: .history).map(Settings.shared.display)
                    )
                    self.feature(
                        "checklist", "Tareas",
                        "Escribí la tarea y el proyecto, la prioridad y el recordatorio en la misma línea.",
                        Settings.shared.shortcut(for: .quickAdd).map(Settings.shared.display)
                    )
                    self.feature(
                        "macbook", "Notch",
                        "Música, agenda, batería y archivos. Llevá el mouse al recorte y se abre.",
                        nil
                    )
                    self.feature(
                        "tray.full", "Estante",
                        "Arrastrá archivos a la notch, sacalos donde los necesites.",
                        nil
                    )
                    self.feature(
                        "cpu", "Agentes",
                        "Qué está corriendo en Claude, Codex y Conductor, y cuál te está esperando.",
                        nil
                    )
                    self.feature(
                        "mic", "Dictado",
                        "Lo que dictás con FluidVoice queda guardado en el portapapeles.",
                        nil
                    )
                }
            }
            .padding(24)
        }
    }

    // LocalizedStringKey y no String: un String que llega por parámetro ya no pasa por la tabla
    // de traducciones, y la fila quedaba en español con el resto en inglés.
    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ shortcut: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var checklist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permisos")
                        .font(.system(size: 20, weight: .bold))
                    Text(self.setup.isReady
                        ? "Está todo listo. Lo opcional lo podés activar cuando quieras."
                        : "macOS pide estos permisos una sola vez. Los opcionales podés saltearlos.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    ForEach(self.setup.steps) { step in
                        self.row(step)
                    }
                }
            }
            .padding(24)
        }
    }

    private func row(_ step: Setup.Step) -> some View {
        HStack(spacing: 12) {
            Image(systemName: step.done ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 16))
                .foregroundStyle(step.done ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tint))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(step.title).font(.system(size: 13, weight: .medium))
                    if step.optional {
                        Text("opcional")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(step.detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if step.done {
                Text("Listo").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(step.actionTitle, action: step.action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}
