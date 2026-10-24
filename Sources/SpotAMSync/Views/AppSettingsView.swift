import SwiftUI
import SyncCore

struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var tab = "sync"
    @ViewState private var pendingAction = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeading(eyebrow: "A TU MANERA", title: "Ajustes", subtitle: "Preferencias de esta app. Las propuestas guardan sus propias opciones.").padding(.horizontal, 28).padding(.top, 28)
            TabView(selection: $tab) {
                ConnectionsView().tabItem { Label("Cuentas", systemImage: "link") }.tag("accounts")
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("Nuevas sincronizaciones").font(.headline)
                                Picker("Dirección predeterminada", selection: preference(\.defaultMode)) { ForEach(SyncMode.allCases) { Text($0.title).tag($0) } }
                                Picker("Si existe en destino", selection: preference(\.options.existingPlaylist)) { ForEach(ExistingPlaylistPolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
                                Toggle("Mantener el orden de las canciones", isOn: preference(\.options.keepOrder))
                                Toggle("Omitir repeticiones", isOn: preference(\.options.skipDuplicates))
                                Text("Estos valores se usan al crear una configuración. Las existentes se editan individualmente en Cola y programación.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Revisiones programadas").font(.headline)
                                Text("La frecuencia y el alcance se eligen por configuración. La programación prepara cambios y avisa; nunca los aplica automáticamente.").font(.callout).foregroundStyle(.secondary)
                                Button("Abrir cola y programación") { model.navigationRequest = .queue }
                            }
                        }
                    }.padding(28)
                }.tabItem { Label("Sincronización", systemImage: "arrow.triangle.2.circlepath") }.tag("sync")
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 17) {
                                Text("Sugerencias del catálogo oficial").font(.headline)
                                Picker("Ordenar candidatos por", selection: preference(\.candidateOrder)) { ForEach(CandidateOrder.allCases, id: \.self) { Text($0.title).tag($0) } }
                                Text("Cambia el orden de las sugerencias en el comparador y en Coincidencias. Las selecciones manuales se conservan.").font(.caption).foregroundStyle(.secondary)
                                Divider()
                                Label("Coincidencia automática estricta", systemImage: "checkmark.shield").font(.callout.weight(.semibold))
                                Text("Artista, grabación, edición, duración y contenido explícito deben ser compatibles. Remasterizaciones, otras ediciones y metadatos inciertos quedan para tu revisión.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Text("La duración no flexibiliza automáticamente la edición. El comparador muestra sus diferencias para que elijas.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(28)
                }.tabItem { Label("Coincidencias", systemImage: "arrow.triangle.branch") }.tag("matching")
                ScrollView {
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Avisos de esta app").font(.headline)
                            Toggle("Propuestas listas para revisar", isOn: preference(\.notifyReview))
                            Toggle("Sincronizaciones verificadas", isOn: preference(\.notifyDone))
                            Toggle("Errores y resultados que requieren revisión", isOn: preference(\.notifyFailure))
                            Divider()
                            HStack {
                                Text(model.workspace.notificationStatus).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Configurar permiso en macOS") { model.workspace.requestNotifications() }
                            }
                            Text("Si no permitís notificaciones, las propuestas y sus mensajes siguen disponibles en la cola y el historial.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(28)
                }.tabItem { Label("Notificaciones", systemImage: "bell") }.tag("notifications")
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Historial y respaldos").font(.headline)
                                Text("Los inventarios, las decisiones y el historial se guardan en este Mac. Los tokens de Spotify permanecen en Keychain.").font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    Button("Exportar historial CSV") { model.exportHistoryCSV() }
                                    Button("Exportar respaldo actual") { model.exportBackup() }.disabled(model.snapshots.isEmpty)
                                }
                                Button("Borrar historial resuelto", role: .destructive) { pendingAction = "history" }
                                Text("Se conservan los registros con escrituras inciertas o en curso que sean necesarios para reconciliar resultados.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Preferencias de la app anterior").font(.headline)
                                Text("Podés importar un JSON de preferencias de Electron. Solo se trasladan opciones compatibles; las conexiones simuladas y los ejemplos no se convierten en datos reales.").font(.callout).foregroundStyle(.secondary)
                                Button("Importar preferencias JSON") { model.importElectronPreferences() }
                                Divider()
                                Button("Eliminar configuraciones y cola", role: .destructive) { pendingAction = "configs" }
                                Button("Desconectar todas las cuentas", role: .destructive) { pendingAction = "disconnect" }
                                Text("Estas acciones se limitan a esta app. No modifican tus bibliotecas en los servicios.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(28)
                }.tabItem { Label("Datos", systemImage: "externaldrive") }.tag("data")
            }
        }
        .disabled(model.isBusy || !model.workspace.loaded)
        .confirmationDialog("¿Confirmás esta acción local?", isPresented: Binding(get: { !pendingAction.isEmpty }, set: { if !$0 { pendingAction = "" } })) {
            Button("Confirmar", role: .destructive) {
                switch pendingAction {
                case "history": model.clearSettledHistory()
                case "configs": model.clearConfigurations()
                case "disconnect": model.disconnectAll()
                default: break
                }
                pendingAction = ""
            }
        } message: {
            Text(pendingAction == "history" ? "Los registros resueltos dejarán de estar disponibles para consultar o deshacer. Los resultados inciertos se conservan." : pendingAction == "configs" ? "Se quitarán las configuraciones y propuestas de la cola. El historial y las bibliotecas se conservan." : "Se eliminará la autorización almacenada por esta app. Podés volver a conectar después.")
        }
    }
    private func preference<T>(_ key: WritableKeyPath<AppPreferences, T>) -> Binding<T> {
        Binding(get: { model.workspace.state.preferences[keyPath: key] }, set: { value in model.workspace.updatePreferences { $0[keyPath: key] = value } })
    }
}
