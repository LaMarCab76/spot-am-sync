import SwiftUI
import SyncCore

struct ConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var clientIDDraft = ""
    @ViewState private var didSave = false

    private var cleanClientID: String { clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasUnsavedID: Bool { cleanClientID != model.spotifyClientID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "Un buen comienzo", title: "Conectá tu música", subtitle: "Autorizá cada servicio para leer tus bibliotecas. Los cambios se revisan y se confirman en un paso separado.")
                if model.isBusy {
                    HStack(spacing: 11) {
                        ProgressView().controlSize(.small)
                        Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancelar") { model.cancel() }
                    }
                }
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 18) {
                        connectionHeader(.spotify)
                        Divider()
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Client ID de Spotify").font(.callout.weight(.semibold))
                            HStack(spacing: 9) {
                                TextField("Pegá el identificador público de tu aplicación", text: $clientIDDraft)
                                    .textFieldStyle(.roundedBorder).controlSize(.large)
                                    .accessibilityLabel("Client ID público de Spotify")
                                    .onChange(of: clientIDDraft) { _, _ in didSave = false }
                                Button("Guardar") {
                                    model.spotifyClientID = cleanClientID
                                    UserDefaults.standard.set(cleanClientID, forKey: "spotifyClientID")
                                    clientIDDraft = cleanClientID
                                    didSave = true
                                }.disabled(cleanClientID.isEmpty || !hasUnsavedID).controlSize(.large)
                            }
                            Text("Es un identificador público del panel de Spotify for Developers. No ingreses un Client Secret.")
                                .font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Registrá esta URL de redirección en tu aplicación de Spotify:").font(.caption).foregroundStyle(.secondary)
                                Text("http://127.0.0.1:43821/callback").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }.padding(.top, 3)
                            if hasUnsavedID {
                                Label("Guardá el identificador antes de conectar.", systemImage: "pencil.circle")
                                    .font(.caption).foregroundStyle(SyncStyle.coral)
                            } else if didSave {
                                Label("Identificador guardado", systemImage: "checkmark.circle")
                                    .font(.caption).foregroundStyle(SyncStyle.green)
                            }
                        }
                        HStack {
                            Text("La autorización se abre en tu navegador.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.accounts[.spotify] != nil {
                                Button("Desconectar") { model.disconnect(.spotify) }
                            }
                            Button { model.connectSpotify() } label: {
                                Label(model.accounts[.spotify] == nil || model.isDemo ? "Conectar Spotify" : "Volver a autorizar", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasUnsavedID)
                        }
                    }
                }
                .disabled(model.isBusy)

                SurfaceCard {
                    VStack(alignment: .leading, spacing: 18) {
                        connectionHeader(.appleMusic)
                        Divider()
                        Notice(title: "Antes de conectar", message: "Iniciá sesión en Música con una suscripción activa de Apple Music. La app debe estar firmada con un equipo de Apple Developer y tener MusicKit habilitado para solicitar acceso a tu biblioteca.", symbol: "checkmark.shield", color: SyncStyle.coral)
                        HStack {
                            Text("macOS te pedirá permiso para acceder a Música.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if model.accounts[.appleMusic] != nil {
                                Button("Desconectar") { model.disconnect(.appleMusic) }
                            }
                            Button { model.connectAppleMusic() } label: {
                                Label(model.accounts[.appleMusic] == nil || model.isDemo ? "Conectar Apple Music" : "Volver a autorizar", systemImage: "music.note")
                            }
                            .buttonStyle(.borderedProminent).tint(SyncStyle.coral)
                        }
                    }
                }
                .disabled(model.isBusy)

                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "flask").font(.system(size: 24)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Explorá antes de conectar").font(.callout.weight(.semibold))
                        Text("La demostración usa bibliotecas de ejemplo. No conecta cuentas ni modifica música real.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(model.isDemo ? "Recargar demo" : "Probar demostración") { model.loadDemo() }
                        .disabled(model.isBusy)
                }.padding(.vertical, 3)
            }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { clientIDDraft = model.spotifyClientID }
        .onChange(of: model.spotifyClientID) { _, value in clientIDDraft = value }
    }

    private func connectionHeader(_ service: MusicService) -> some View {
        HStack(spacing: 12) {
            ServiceMark(service: service, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name).font(.title3.weight(.semibold))
                if let account = model.accounts[service] {
                    Text(model.isDemo ? "Cuenta de ejemplo · \(account.displayName)" : account.displayName)
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Todavía sin conectar").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusPill(title: model.isDemo ? "Ejemplo" : model.accounts[service] != nil ? "Conectado" : "Pendiente",
                       symbol: model.isDemo ? "flask" : model.accounts[service] != nil ? "checkmark.circle.fill" : "circle.dotted",
                       color: model.accounts[service] != nil ? SyncStyle.green : .secondary)
        }
    }
}
