import SwiftUI
import SyncCore

// Use the macOS 14 property wrapper even when the SDK also declares a State macro.
// SwiftPM's command-line toolchain may not include the newer SwiftUI macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

enum SyncStyle {
    static let green = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.40, green: 0.85, blue: 0.65, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.43, blue: 0.30, alpha: 1)
    })
    static let coral = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.57, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.76, green: 0.25, blue: 0.20, alpha: 1)
    })
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.09)
}

struct SurfaceCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SyncStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(SyncStyle.border, lineWidth: 1))
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.6).foregroundStyle(SyncStyle.green)
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ServiceMark: View {
    let service: MusicService
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: service == .spotify ? "waveform" : "music.note")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(service == .spotify ? SyncStyle.green : SyncStyle.coral)
            .frame(width: size, height: size)
            .background((service == .spotify ? SyncStyle.green : SyncStyle.coral).opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(service.name)
    }
}

struct StatusPill: View {
    let title: String
    var symbol: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize()
    }
}

struct Notice: View {
    let title: String
    let message: String
    var symbol = "info.circle"
    var color: Color = .secondary
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.body).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(SyncStyle.green)
                .frame(width: 70, height: 70).background(SyncStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390)
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Buscar"
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Limpiar búsqueda").accessibilityLabel("Limpiar búsqueda")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(SyncStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SyncStyle.border))
        .accessibilityLabel(prompt)
    }
}

extension OperationKind {
    var entityTitle: String {
        switch self {
        case .createPlaylist, .removePlaylist, .renamePlaylist, .replacePlaylistTracks, .addPlaylistTracks: return "Playlists"
        case .saveTracks, .removeTracks: return "Canciones"
        case .saveAlbums, .removeAlbums: return "Álbumes"
        }
    }
    var symbol: String {
        switch self {
        case .createPlaylist: return "text.badge.plus"
        case .removePlaylist: return "text.badge.minus"
        case .renamePlaylist: return "pencil"
        case .replacePlaylistTracks: return "arrow.triangle.2.circlepath"
        case .addPlaylistTracks: return "text.badge.plus"
        case .saveTracks: return "music.note"
        case .removeTracks: return "minus.circle"
        case .saveAlbums: return "square.stack"
        case .removeAlbums: return "minus.circle"
        }
    }
    var destructiveExplanation: String? {
        switch self {
        case .removePlaylist: return "Quita esta playlist de la biblioteca de destino."
        case .replacePlaylistTracks: return "Sustituye el contenido y el orden del destino; puede quitar canciones de esa playlist."
        case .removeTracks: return "Quita la canción de las canciones guardadas del destino."
        case .removeAlbums: return "Quita el álbum de los álbumes guardados del destino."
        default: return nil
        }
    }
    var isRemoval: Bool {
        switch self { case .removePlaylist, .removeTracks, .removeAlbums: return true; default: return false }
    }
}
