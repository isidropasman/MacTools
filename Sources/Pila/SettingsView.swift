import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var calendar: CalendarManager
    @State private var recording = false
    @State private var trusted = Paster.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Atajo") {
                HStack {
                    Text("Abrir Pila")
                    Spacer()
                    Button(self.recording ? "Apretá las teclas…" : self.settings.shortcutDisplay) {
                        self.recording.toggle()
                    }
                    .frame(minWidth: 130)
                }
                Text("⌘⇧V choca con «pegar sin formato» en Chrome, Slack y Notion. ⌘⇧B está libre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Al elegir un item") {
                Toggle("Pegar automáticamente", isOn: self.$settings.pasteOnPick)
                if self.settings.pasteOnPick, !self.trusted {
                    HStack(spacing: 8) {
                        Label("Necesita permiso de Accesibilidad", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Button("Dar permiso") {
                            Paster.requestPermission()
                        }
                        .controlSize(.small)
                    }
                }
                Text(self.settings.pasteOnPick
                    ? "Enter copia y pega en la app donde estabas."
                    : "Enter solo copia; pegás vos con ⌘V.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Historial") {
                Toggle("Guardar dictados de FluidVoice", isOn: self.$settings.ingestDictations)
                LabeledContent("Máximo de imágenes") {
                    TextField("", value: self.$settings.maxImages, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Tope de imágenes (GB)") {
                    TextField("", value: self.$settings.maxImageGB, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Text("El texto no se borra nunca. Los fijados tampoco.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cuentas de calendario") {
                if self.calendar.accounts.isEmpty {
                    Text("Sin cuentas. Agregalas en Ajustes → Cuentas de Internet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(self.calendar.accounts) { account in
                        LabeledContent(account.calendarTitles.first ?? account.sourceTitle) {
                            TextField(account.label, text: Binding(
                                get: { AccountLabels.custom()[account.id] ?? "" },
                                set: { AccountLabels.setCustom($0, for: account.id) }
                            ))
                            .frame(width: 110)
                        }
                    }
                    Text("Todas las cuentas de Google se llaman «Google» en el sistema. Poné acá cómo querés verlas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sistema") {
                Toggle("Abrir al iniciar sesión", isOn: self.$launchAtLogin)
                    .onChange(of: self.launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .scrollIndicators(.never)
        .background(HotKeyRecorder(recording: self.$recording, settings: self.settings))
        .onAppear { self.trusted = Paster.isTrusted }
    }
}

/// Captures the next key press while armed. A plain NSView monitor beats a custom control here.
private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var recording: Bool
    let settings: Settings

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setRecording(self.recording, settings: self.settings) {
            self.recording = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func setRecording(_ recording: Bool, settings: Settings, done: @escaping () -> Void) {
            if recording, self.monitor == nil {
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let modifiers = Settings.carbonModifiers(from: event.modifierFlags)
                    guard modifiers != 0 else { return nil }
                    settings.keyCode = UInt32(event.keyCode)
                    settings.modifiers = modifiers
                    done()
                    return nil
                }
            } else if !recording, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
