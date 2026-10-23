import Foundation

/// Offline examples: these IDs and recording codes are deliberately synthetic.
public enum DemoFixtures {
    public static func snapshots() -> [LibrarySnapshot] {
        let date = Date(timeIntervalSince1970: 1_792_728_000)
        let spotify = LibrarySnapshot(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            account: ConnectedAccount(id: "demo-spotify", service: .spotify, displayName: "Lucía · Demo",
                                      storefront: "AR", connectionRevision: "demo-spotify-v1"),
            fetchedAt: date,
            playlists: [
                Playlist(id: "sp-ruta", name: "Ruta al sur", description: "Canciones para viajar, con una favorita repetida.",
                         tracks: [spMusica, spCrimen, spMusica, spPuente], version: "demo-ruta-1"),
                Playlist(id: "sp-cafe", name: "Café de mañana", description: "Un comienzo tranquilo.",
                         tracks: [spCrimen, spPuente, spCrimen], version: "demo-cafe-1"),
                Playlist(id: "sp-personales", name: "Grabaciones personales", tracks: [spMissing], version: "demo-personales-1")
            ],
            savedTracks: [spMusica, spCrimen, spLoose],
            savedAlbums: [spAlbum, Album(id: "sp-bocanada-parcial", title: "Bocanada", artist: "Gustavo Cerati",
                                        tracks: [spPuente], isCompleteAlbum: false)])
        let apple = LibrarySnapshot(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            account: ConnectedAccount(id: "demo-apple", service: .appleMusic, displayName: "Lucía · Demo",
                                      storefront: "ar", connectionRevision: "demo-apple-v1"),
            fetchedAt: date,
            playlists: [
                Playlist(id: "am-ruta", name: "Ruta al sur", description: "Mi selección anterior.",
                         tracks: [amCrimen, amMusica], version: "demo-ruta-2"),
                Playlist(id: "am-archivo", name: "Archivo de verano", tracks: [amExtra], version: "demo-archivo-1"),
                Playlist(id: "am-seguida", name: "Novedades de la semana", tracks: [amMusica], editable: false,
                         ownership: .followed, version: "demo-seguida-1")
            ],
            savedTracks: [amMusica, amPuente, amExtra],
            savedAlbums: [Album(id: "am-album-anterior", catalogID: "demo-am-cat-album-anterior", title: "Selección de verano",
                                artist: "Artista de demostración", upc: "DEMO-UPC-VERANO", tracks: [amExtra])])
        return [spotify, apple]
    }

    public static func decisions() -> MatchDecisions {
        let pairs = [(spMusica, amMusica), (spCrimen, amCrimen), (spPuente, amPuente), (spTe, amTe), (spLoose, amLoose), (spExtra, amExtra)]
        return MatchDecisions(
            tracks: pairs.map { source, target in
                TrackMatch(sourceService: .spotify, source: source, candidates: [target], selected: target,
                           confidence: .exact, reason: "Coincidencia confirmada en el catálogo de demostración.")
            } + [TrackMatch(sourceService: .spotify, source: spMissing, confidence: .unavailable,
                            reason: "Esta grabación local no tiene una edición disponible en Apple Music.")],
            albums: [AlbumMatch(sourceService: .spotify, source: spAlbum, candidates: [amAlbum], selected: amAlbum,
                                confidence: .exact, reason: "Misma edición completa, confirmada para la demo.")],
            playlists: [PlaylistLink(spotifyID: "sp-ruta", appleMusicID: "am-ruta")],
            protectedPlaylistIDs: [.appleMusic: ["am-seguida"]])
    }

    private static func song(_ id: String, _ title: String, _ artist: String, _ album: String, _ duration: Int, _ code: String) -> Track {
        Track(id: id, catalogID: id.hasPrefix("am-") ? "demo-cat-\(id)" : nil, title: title, artist: artist,
              albumTitle: album, durationMS: duration, isrc: "DEMO-\(code)", explicit: false)
    }

    private static let spMusica = song("sp-musica", "De música ligera", "Soda Stereo", "Canción animal", 212_000, "MUSICA")
    private static let amMusica = song("am-musica", "De música ligera", "Soda Stereo", "Canción animal", 212_000, "MUSICA")
    private static let spCrimen = song("sp-crimen", "Crimen", "Gustavo Cerati", "Ahí vamos", 232_000, "CRIMEN")
    private static let amCrimen = song("am-crimen", "Crimen", "Gustavo Cerati", "Ahí vamos", 232_000, "CRIMEN")
    private static let spPuente = song("sp-puente", "Puente", "Gustavo Cerati", "Bocanada", 273_000, "PUENTE")
    private static let amPuente = song("am-puente", "Puente", "Gustavo Cerati", "Bocanada", 273_000, "PUENTE")
    private static let spTe = song("sp-te", "Té para tres", "Soda Stereo", "Canción animal", 161_000, "TE")
    private static let amTe = song("am-te", "Té para tres", "Soda Stereo", "Canción animal", 161_000, "TE")
    private static let spLoose = song("sp-suelta", "Seguir viviendo sin tu amor", "Luis Alberto Spinetta", "Pelusón of milk", 161_000, "SUELTA")
    private static let amLoose = song("am-suelta", "Seguir viviendo sin tu amor", "Luis Alberto Spinetta", "Pelusón of milk", 161_000, "SUELTA")
    private static let spExtra = song("sp-extra", "Un día de verano", "Artista de demostración", "Selección de verano", 185_000, "VERANO")
    private static let amExtra = song("am-extra", "Un día de verano", "Artista de demostración", "Selección de verano", 185_000, "VERANO")
    private static let spMissing = Track(id: "sp-local-ensayo", title: "Ensayo en casa (en vivo)", artist: "Mi banda",
                                         albumTitle: "Grabaciones personales", durationMS: 198_000, available: false, isLocal: true)
    private static let spAlbum = Album(id: "sp-cancion-animal", title: "Canción animal", artist: "Soda Stereo",
                                      upc: "DEMO-UPC-ANIMAL", tracks: [spMusica, spTe])
    private static let amAlbum = Album(id: "am-cancion-animal", catalogID: "demo-cat-cancion-animal", title: "Canción animal",
                                      artist: "Soda Stereo", upc: "DEMO-UPC-ANIMAL", tracks: [amMusica, amTe])
}
