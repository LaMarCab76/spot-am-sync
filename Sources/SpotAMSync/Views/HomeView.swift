import SwiftUI
import SyncCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    var navigate: (AppDestination) -> Void
    private var pending: Int { model.decisions.tracks.filter { $0.selected == nil && $0.decision != .omitted }.count }
    private var nextReview: Date? { model.workspace.state.profiles.filter { $0.schedule.enabled }.compactMap(\.schedule.nextReview).min() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "SPOTIFY + APPLE MUSIC", title: "Tu música, en sintonía.", subtitle: "Prepará los cambios. Elegí las versiones. Confirmá a tu ritmo.")
                    Button { model.editingProfileID = nil; navigate(.newSync) } label: { Label("Nueva sincronización", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy).padding(.top, 24)
                }
                if model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) { ServiceMark(service: .spotify, size: 50); Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary); ServiceMark(service: .appleMusic, size: 50) }
                        Text("Dos bibliotecas. Un lugar para revisarlas.").font(.system(size: 25, weight: .medium))
                        Text("Conectá tus cuentas para preparar sincronizaciones, o compará Spotify con un XML de Música usando la lista manual.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 550, alignment: .leading)
                        HStack(spacing: 14) {
                            Button("Conectar cuentas") { navigate(.connections) }.buttonStyle(.borderedProminent).controlSize(.large)
                            Button("Probar demostración") { model.loadDemo() }.controlSize(.large)
                        }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                }
                HStack(alignment: .top, spacing: 28) {
                    metric("Para revisar", value: "\(pending)", detail: "Coincidencias pendientes", symbol: "sparkle.magnifyingglass", action: { navigate(.matches) })
                    Divider()
                    metric("Propuestas listas", value: "\(model.workspace.state.jobs.filter { $0.state == .ready }.count)", detail: "Esperando confirmación", symbol: "checklist", action: { navigate(.queue) })
                    Divider()
                    metric("Próxima revisión", value: nextReview.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "es_AR"))) } ?? "A tu ritmo", detail: "La programación solo prepara", symbol: "calendar", action: { navigate(.queue) })
                }.frame(height: 116)
                Divider()
                HStack {
                    Text("Tus playlists").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Ver todas") { navigate(.playlists) }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { model.refreshLibraries() } label: { Image(systemName: "arrow.clockwise") }.disabled(!model.canAnalyze).help("Actualizar bibliotecas")
                }
                if model.snapshots.isEmpty {
                    Text(model.accounts.count == 2 ? "Actualizá las bibliotecas para ver tus playlists y elegir el alcance." : "Tus playlists aparecerán después de conectar y leer las bibliotecas.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 10)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 22)], alignment: .leading, spacing: 24) {
                        ForEach(model.snapshots, id: \.account.service) { snapshot in
                            ForEach(snapshot.playlists.prefix(6)) { playlist in
                                Button { model.showPlaylist(playlist, service: snapshot.account.service) } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ArtworkView(url: playlist.artworkURL, title: playlist.name, service: snapshot.account.service).aspectRatio(1, contentMode: .fit)
                                        Text(playlist.name).font(.callout.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                                        Text("\(snapshot.account.service.name) · \(playlist.tracks.count) canciones\(playlist.contentsComplete ? "" : "+")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Tus cuentas").font(.headline)
                        ForEach(MusicService.allCases) { service in
                            HStack(spacing: 12) {
                                ServiceMark(service: service)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(service.name).font(.callout.weight(.medium))
                                    Text(model.accounts[service]?.displayName ?? "Sin conectar").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        Button("Administrar cuentas") { navigate(.connections) }.buttonStyle(.link)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Última actividad").font(.headline)
                        if let latest = model.history.first {
                            Text(latest.status.displayTitle).font(.callout.weight(.medium))
                            Text(latest.message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                            Text(latest.startedAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            Button("Abrir historial") { navigate(.history) }.buttonStyle(.link)
                        } else {
                            Text("Los cambios verificados y los resultados pendientes aparecerán acá.").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Agregar a Apple Music con XML") { navigate(.manual) }.buttonStyle(.link)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(32).frame(maxWidth: 1280, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    private func metric(_ title: String, value: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: value.count > 14 ? 18 : 30, weight: .medium)).tracking(-0.5).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
}

struct ArtworkView: View {
    let url: String?
    let title: String
    let service: MusicService
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var remote: URL? {
        guard let url, let value = URL(string: url), value.scheme == "https" else { return nil }
        return value
    }
    var body: some View {
        GeometryReader { size in
            ZStack {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let remote {
                    AsyncImage(url: remote) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                } else { placeholder }
                VStack {
                    Spacer()
                    HStack { Spacer(); ServiceMark(service: service, size: 25).padding(10) }
                }
            }.frame(width: size.size.width, height: size.size.height).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(SyncStyle.border))
        }.accessibilityLabel("Portada de \(title)")
    }
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 12)
        }
    }
}
