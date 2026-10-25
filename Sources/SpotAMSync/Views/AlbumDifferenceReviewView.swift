import SwiftUI
import SyncCore

struct AlbumDifferenceReviewView: View {
    @EnvironmentObject private var model: AppModel
    let difference: LibraryDifference
    private var sync: LibrarySyncCoordinator { model.librarySync }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agrupar canciones por álbum no confirma una edición completa guardada. Elegir una edición prepara una propuesta y requiere otra confirmación.")
                .font(.caption).foregroundStyle(.secondary)
            Button(sync.searchingAlbumIDs.contains(difference.id) ? "Buscando ediciones…" : "Buscar ediciones en \(sync.albumDestination(difference).name)") {
                sync.searchAlbum(difference)
            }.disabled(sync.isApplying || sync.searchingAlbumIDs.contains(difference.id))
            ForEach(sync.albumCandidates[difference.id] ?? []) { album in
                HStack(spacing: 12) {
                    ArtworkView(url: album.artworkURL, title: album.title, service: sync.albumDestination(difference)).frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title).font(.callout.weight(.semibold))
                        Text("\(album.artist) · \(album.tracks.count) pistas\(album.isCompleteAlbum ? " · Edición completa" : " · Contenido parcial")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Elegir álbum completo") { sync.chooseAlbum(album, for: difference) }
                        .disabled(sync.isApplying || !album.available || !album.isCompleteAlbum)
                }
            }
        }.padding(.vertical, 8)
    }
}
