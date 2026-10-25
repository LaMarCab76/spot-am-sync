import Foundation
import CoreGraphics
import ImageIO
import SyncCore

/// Provenance travels with the bytes, never with music identity or match approval.
public enum ArtworkOrigin: String, Sendable, Codable {
    case spotifyCatalog, appleMusicCatalog, appleMusicLibrary, localMusicFile, itunesCatalog
    /// A Spotify cover offered when the XML has none. It is not Apple artwork evidence.
    case spotifyReference
}

public struct ArtworkImage: Sendable, Equatable {
    public let data: Data
    public let origin: ArtworkOrigin
    public init(data: Data, origin: ArtworkOrigin) { self.data = data; self.origin = origin }
}

public enum ArtworkComparisonState: String, Sendable, Codable {
    case equal, different, possible, unavailable
    public var label: String {
        switch self {
        case .equal: return "Portada visualmente igual"
        case .different: return "Portada diferente"
        case .possible: return "Posible coincidencia de portada"
        case .unavailable: return "Comparación de portada no disponible"
        }
    }
}

/// A visual aid for human review. It never changes CatalogMatcher confidence.
/// Native ImageIO applies orientation; CoreGraphics renders a bounded sRGB raster.
/// Equality means equal normalized pixels, not equal URLs or musical identity.
public struct ArtworkComparison: Sendable, Equatable {
    public let state: ArtworkComparisonState
    public let detail: String
    public let normalizedPixelDifference: Double?

    public static func compare(_ source: ArtworkImage?, _ candidate: ArtworkImage?) -> ArtworkComparison {
        guard let source, let candidate else { return unavailable("Falta una de las portadas o no pudo descargarse.") }
        guard source.origin != .spotifyReference, candidate.origin != .spotifyReference else {
            return unavailable("La portada de Spotify es sólo una referencia; no prueba la portada de Música.")
        }
        guard let left = raster(source.data), let right = raster(candidate.data) else {
            return unavailable("Una de las imágenes está vacía, dañada o excede el límite de lectura.")
        }
        let aspectDelta = abs(left.aspect - right.aspect) / max(left.aspect, right.aspect)
        if left.pixels == right.pixels && aspectDelta < 0.001 {
            return .init(state: .equal, detail: "Los píxeles normalizados coinciden. Esto no confirma la canción ni su edición.", normalizedPixelDifference: 0)
        }
        let difference = zip(left.pixels, right.pixels).enumerated().reduce(0.0) { sum, item in
            // Compare RGB; alpha has already been composited over white.
            item.offset % 4 == 3 ? sum : sum + abs(Double(item.element.0) - Double(item.element.1)) / 255
        } / Double(96 * 96 * 3)
        // Conservative heuristics, not probabilities. Compression, crops and
        // minor alterations remain "possible" for a person to inspect.
        let state: ArtworkComparisonState = difference >= 0.22 ? .different : .possible
        return .init(state: state,
                     detail: state == .different ? "La comparación de píxeles muestra diferencias visuales amplias; revisá las imágenes."
                         : "Hay diferencias de píxeles o proporción; pueden deberse a tamaño, compresión, recorte o edición. Revisá las imágenes.",
                     normalizedPixelDifference: difference)
    }

    /// HTTPS only, no account tokens, cookies, file URLs or inherited credentials.
    /// Always loads image content; even equal URLs are not equality evidence.
    public static func compare(sourceURL: String?, sourceOrigin: ArtworkOrigin,
                               candidateURL: String?, candidateOrigin: ArtworkOrigin,
                               transport: any ProviderHTTPTransport = URLSessionProviderTransport()) async -> ArtworkComparison {
        guard sourceOrigin != .spotifyReference, candidateOrigin != .spotifyReference else {
            return unavailable("La portada de Spotify es sólo una referencia; no prueba la portada de Música.")
        }
        guard sourceURL != nil, candidateURL != nil else { return unavailable("Falta una de las portadas.") }
        async let source = load(url: sourceURL, origin: sourceOrigin, transport: transport)
        async let candidate = load(url: candidateURL, origin: candidateOrigin, transport: transport)
        let images = await (source, candidate)
        guard !Task.isCancelled else { return unavailable("Comparación cancelada.") }
        return compare(images.0, images.1)
    }

    public static func load(url raw: String?, origin: ArtworkOrigin,
                            transport: any ProviderHTTPTransport = URLSessionProviderTransport()) async -> ArtworkImage? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, !Task.isCancelled else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let response = try? await transport.send(request), response.statusCode == 200,
              !Task.isCancelled, raster(response.data) != nil else { return nil }
        return ArtworkImage(data: response.data, origin: origin)
    }

    public static func unavailable(_ detail: String) -> ArtworkComparison {
        .init(state: .unavailable, detail: detail, normalizedPixelDifference: nil)
    }

    /// Supply candidates from the Spotify provider/snapshot only. Root UI can
    /// display the result beside an XML song without copying it into that song's
    /// artworkURL. No first-candidate guessing when multiple editions exist.
    public static func spotifyReference(for xmlTrack: Track, candidates: [Track]) -> Track? {
        guard xmlTrack.id.hasPrefix("apple-music-xml:") else { return nil }
        var source = xmlTrack; source.isLocal = false
        let match = CatalogMatcher.track(source, candidates: candidates, sourceService: .appleMusic)
        guard let selected = match.selected, !selected.id.hasPrefix("itunes:"), selected.artworkURL != nil else { return nil }
        return selected
    }

    /// Preferred fallback boundary: returned bytes carry reference provenance,
    /// which compare() refuses as evidence about the Apple-side cover.
    public static func loadSpotifyReference(for xmlTrack: Track, confirmedMatch: TrackMatch,
                                            transport: any ProviderHTTPTransport = URLSessionProviderTransport()) async -> ArtworkImage? {
        guard let track = spotifyReference(for: xmlTrack, confirmedMatch: confirmedMatch) else { return nil }
        return await load(url: track.artworkURL, origin: .spotifyReference, transport: transport)
    }

    /// Also accepts a previously confirmed manual mapping. Callers must supply
    /// the Spotify-side track; XML/catalog IDs alone cannot prove the provider.
    public static func spotifyReference(for xmlTrack: Track, confirmedMatch: TrackMatch) -> Track? {
        guard xmlTrack.id.hasPrefix("apple-music-xml:"),
              confirmedMatch.sourceService == .appleMusic, confirmedMatch.source == xmlTrack,
              confirmedMatch.decision != .pending, confirmedMatch.decision != .omitted,
              confirmedMatch.decision == .manual || confirmedMatch.manualSelection == true ||
                (confirmedMatch.confidence == .exact && (confirmedMatch.searchCoverage == nil || confirmedMatch.searchCoverage == .complete)),
              let selected = confirmedMatch.selected, selected.available, !selected.isLocal,
              !selected.id.hasPrefix("itunes:"), selected.artworkURL != nil else { return nil }
        return selected
    }

    private static func raster(_ data: Data) -> (pixels: [UInt8], aspect: Double)? {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 255, count: 96 * 96 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 96, height: 96, bitsPerComponent: 8,
                                          bytesPerRow: 96 * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
            return true
        }
        return rendered ? (pixels, Double(image.width) / Double(image.height)) : nil
    }
}
