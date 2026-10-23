import SwiftUI
import SyncCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    var navigate: (AppDestination) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    PageHeading(eyebrow: "Dos servicios. Una colección.", title: "Todo lo que te gusta, cerca.", subtitle: "Compará tus bibliotecas, resolvé las diferencias y elegí exactamente qué sincronizar.")
                    Button { navigate(.connections) } label: { Label("Conexiones", systemImage: "link") }
                        .padding(.top, 25)
                }
                HStack(spacing: 8) {
                    workflowStep("1", title: "Conectar", active: model.accounts.count < 2)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    workflowStep("2", title: "Analizar", active: model.accounts.count == 2 && model.plan == nil)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    workflowStep("3", title: "Revisar y elegir", active: model.plan != nil)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    workflowStep("4", title: "Confirmar", active: false)
                }.font(.caption)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(MusicService.allCases) { service in
                        LibraryOverviewCard(service: service, snapshot: model.snapshots.first { $0.account.service == service }, account: model.accounts[service], isDemo: model.isDemo)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Cómo querés sincronizar").font(.title3.weight(.semibold))
                    ModeSelectionView()
                }

                SurfaceCard {
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.plan == nil ? "Primero, una vista previa" : "Tu vista previa está lista")
                                .font(.headline)
                            Text(model.plan == nil ? "El análisis lee las bibliotecas y prepara los cambios para tu revisión." : "Revisá las coincidencias y seleccioná las operaciones que querés aplicar.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !model.canAnalyze && !model.isBusy {
                                Text("Conectá ambos servicios o cargá una demostración para comenzar.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 9) {
                            Button { model.analyze() } label: {
                                Label(model.plan == nil ? "Analizar bibliotecas" : "Volver a analizar", systemImage: "sparkle.magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.canAnalyze || model.isBusy)
                            if model.plan != nil {
                                Button("Revisar cambios →") { navigate(.review) }.buttonStyle(.link)
                            } else if model.accounts.isEmpty {
                                Button("Explorar con datos de ejemplo") { model.loadDemo() }.buttonStyle(.link).disabled(model.isBusy)
                            }
                        }
                    }
                }
                if model.isBusy {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.statusText).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancelar") { model.cancel() }
                    }
                }
            }.padding(28).frame(maxWidth: 1150).frame(maxWidth: .infinity)
        }
    }

    private func workflowStep(_ number: String, title: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Text(number).font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                .background(active ? SyncStyle.green.opacity(0.14) : Color.primary.opacity(0.05), in: Circle())
            Text(title).fontWeight(active ? .semibold : .regular)
        }.foregroundStyle(active ? SyncStyle.green : .secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryOverviewCard: View {
    let service: MusicService
    let snapshot: LibrarySnapshot?
    let account: ConnectedAccount?
    let isDemo: Bool

    var body: some View {
        let membership = snapshot?.libraryMembership
        return SurfaceCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 11) {
                    ServiceMark(service: service)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.name).font(.headline)
                        Text(isDemo ? "Biblioteca de ejemplo" : account?.displayName ?? "Sin conectar")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 13) {
                    metric("Playlists", count: snapshot?.playlists.count, complete: snapshot?.coverage.playlists ?? false)
                    metric("Canciones guardadas", count: snapshot?.savedTracks.count, complete: snapshot?.coverage.tracks ?? false)
                    metric("Álbumes guardados", count: snapshot?.savedAlbums.count, complete: snapshot?.coverage.albums ?? false)
                    membershipMetric("Canciones fuera", count: membership?.outsideTrackCount)
                    membershipMetric("Álbumes completos fuera", count: membership?.outsideCompleteAlbumCount)
                    metric("Álbumes parciales", count: snapshot.map { $0.savedAlbums.filter { !$0.isCompleteAlbum }.count }, complete: snapshot?.coverage.albums ?? false)
                }
                if let membership {
                    SavedLibraryDetail(membership: membership)
                }
                if let snapshot {
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.complete ? "checkmark.circle" : "exclamationmark.circle")
                        Text(snapshot.complete ? "Lectura completa" : "Lectura parcial · los totales pueden variar")
                    }.font(.system(size: 10)).foregroundStyle(snapshot.complete ? SyncStyle.green : SyncStyle.coral)
                    if !snapshot.complete {
                        Text("+ indica elementos leídos en colecciones incompletas. Los totales fuera de playlists pendientes se muestran como —.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(snapshot.fetchedAt, format: .dateTime.day().month().hour().minute()).font(.system(size: 10)).foregroundStyle(.tertiary)
                    ForEach(Array(snapshot.coverage.notes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(account == nil ? "Conectá la cuenta para comenzar." : "Analizá la biblioteca para ver los totales.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metric(_ title: String, count: Int?, complete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.map { "\($0)\(complete ? "" : "+")" } ?? "—")
                .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }

    private func membershipMetric(_ title: String, count: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.map(String.init) ?? "—")
                .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if snapshot != nil && count == nil {
                Text("Por confirmar").font(.system(size: 10)).foregroundStyle(SyncStyle.coral)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct SavedLibraryDetail: View {
    let membership: LibraryMembership

    private var outsideTracks: [SavedTrackMembership] { membership.tracks.filter { $0.membership == .outsidePlaylists } }
    private var outsideAlbums: [SavedAlbumMembership] {
        membership.albums.filter { !$0.classifiesSavedTracksOnly && $0.membership == .outsidePlaylists }
    }
    private var unknownTracks: [SavedTrackMembership] { membership.tracks.filter { $0.membership == .unknown } }
    private var unknownAlbums: [SavedAlbumMembership] { membership.albums.filter { $0.membership == .unknown } }
    private var hasPartialAlbums: Bool { membership.albums.contains(where: \.classifiesSavedTracksOnly) }
    private var hasUnknownTotals: Bool { membership.outsideTrackCount == nil || membership.outsideCompleteAlbumCount == nil }
    private var rowCount: Int { outsideTracks.count + outsideAlbums.count + unknownTracks.count + unknownAlbums.count }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                if !membership.playlistsComplete {
                    Text("Lectura provisional: faltan playlists, su contenido o sus identificadores. No se puede confirmar qué queda fuera.")
                        .foregroundStyle(SyncStyle.coral)
                } else if hasUnknownTotals {
                    Text("Los totales siguen por confirmar: faltan datos guardados o pistas para clasificar. Se muestran los elementos conocidos.")
                        .foregroundStyle(.secondary)
                }
                if hasPartialAlbums {
                    Text("En álbumes parciales se clasifican solo las pistas guardadas, incluidas en las canciones de este detalle. No se cuentan como álbumes completos.")
                        .foregroundStyle(.secondary)
                }
                if rowCount == 0 {
                    Text(hasUnknownTotals ? "Todavía no hay contenido confirmado fuera de playlists." : "No hay contenido guardado fuera de playlists.")
                        .foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            trackSection("Canciones fuera de playlists", entries: outsideTracks)
                            albumSection("Álbumes completos fuera de playlists", entries: outsideAlbums)
                            trackSection("Canciones por clasificar", entries: unknownTracks)
                            albumSection("Álbumes por clasificar", entries: unknownAlbums)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                    }
                    .frame(height: min(220, CGFloat(rowCount) * 43 + CGFloat(sectionCount) * 29))
                }
            }
            .font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
        } label: {
            Text("Guardado fuera de playlists").font(.caption.weight(.medium))
        }
    }

    private var sectionCount: Int {
        [outsideTracks.isEmpty, outsideAlbums.isEmpty, unknownTracks.isEmpty, unknownAlbums.isEmpty].filter { !$0 }.count
    }

    @ViewBuilder
    private func trackSection(_ title: String, entries: [SavedTrackMembership]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.caption.weight(.semibold)).padding(.top, 2)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                detailRow(title: entry.track.title, subtitle: [entry.track.artist, entry.track.albumTitle].filter { !$0.isEmpty }.joined(separator: " · "), icon: "music.note")
            }
        }
    }

    @ViewBuilder
    private func albumSection(_ title: String, entries: [SavedAlbumMembership]) -> some View {
        if !entries.isEmpty {
            Text(title).font(.caption.weight(.semibold)).padding(.top, 2)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                detailRow(title: entry.album.title, subtitle: "\(entry.album.artist) · \(albumScope(entry))", icon: "square.stack")
            }
        }
    }

    private func albumScope(_ entry: SavedAlbumMembership) -> String {
        if entry.album.tracks.isEmpty { return "Sin pistas disponibles · desconocido" }
        if entry.classifiesSavedTracksOnly { return "Álbum parcial · solo \(entry.album.tracks.count) pistas guardadas" }
        return "Álbum completo · \(entry.album.tracks.count) pistas"
    }

    private func detailRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 15).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .help("\(title)\n\(subtitle)")
        .accessibilityElement(children: .combine)
    }
}

struct ModeSelectionView: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    private var selection: Binding<SyncMode> {
        Binding(get: { model.mode }, set: { newMode in
            guard newMode != model.mode else { return }
            model.mode = newMode
            model.rebuildPlan()
            model.selectedOperationIDs.removeAll()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact {
                Picker("Modo", selection: selection) {
                    ForEach(SyncMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.menu).frame(maxWidth: 370, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(SyncMode.allCases) { mode in
                        Button { selection.wrappedValue = mode } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: mode == .merge ? "arrow.triangle.merge" : mode == .spotifyBase ? "waveform" : "music.note")
                                    Spacer()
                                    Image(systemName: model.mode == mode ? "largecircle.fill.circle" : "circle")
                                }.font(.system(size: 16)).foregroundStyle(model.mode == mode ? SyncStyle.green : .secondary)
                                Text(mode.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                Text(description(mode)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(15).frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                            .background(model.mode == mode ? SyncStyle.green.opacity(0.06) : SyncStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.mode == mode ? SyncStyle.green.opacity(0.65) : SyncStyle.border, lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                    }
                }
            }
            Label("Cambiar el modo recalcula la vista previa y borra la selección de cambios.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.mode != .merge && !compact {
                Text("Los modos con una biblioteca base pueden proponer bajas o reemplazos en el destino. Cada cambio requiere tu selección y confirmación.")
                    .font(.caption).foregroundStyle(SyncStyle.coral).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(model.isBusy)
    }

    private func description(_ mode: SyncMode) -> String {
        switch mode {
        case .merge: return "Sumá lo que falta en cada servicio, sin proponer bajas."
        case .spotifyBase: return "Tomá Spotify como referencia para los cambios en Apple Music."
        case .appleMusicBase: return "Tomá Apple Music como referencia para los cambios en Spotify."
        }
    }
}
