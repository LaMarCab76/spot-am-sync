import AppKit
import SwiftUI
import XCTest
import SyncCore
@testable import SpotAMSync

@MainActor
final class LibraryProgressLayoutTests: XCTestCase {
    private let longName = String(repeating: "Viajes, versiones en vivo y recopilaciones especiales 🎵 — ", count: 6)

    private var states: [LibraryProgressPresentation] {
        var playlists = (0..<250).map { LibraryReadProgress.PlaylistStatus(id: $0, name: longName + "\($0)", total: 999) }
        playlists[0].state = .reading
        let reading = LibraryReadProgress(stage: .playlistTracks, received: 9, total: 250,
            itemName: longName, itemReceived: 999, itemTotal: 1000, playlists: playlists)
        var waiting = reading; waiting.waitingUntil = Date().addingTimeInterval(60)
        var expiredWait = waiting; expiredWait.waitingUntil = Date().addingTimeInterval(-1)
        playlists[0].state = .partial
        return [
            .init(title: "Sincronización", detail: "Elegí las fuentes para empezar."),
            .init(read: .init(stage: .savedTracks)),
            .init(read: .init(stage: .savedTracks, received: 50, total: 100)),
            .init(read: .init(stage: .savedAlbums, itemName: longName, itemReceived: 50)),
            .init(read: .init(stage: .playlistList, total: 0)),
            .init(read: .init(stage: .playlistList, received: 1, total: 250, playlists: Array(playlists.prefix(1)))),
            .init(read: reading),
            .init(read: .init(stage: .playlistTracks, received: 10, total: 250, playlists: playlists)),
            .init(read: reading), .init(read: waiting), .init(read: expiredWait), .init(read: reading),
            .init(title: "Leyendo fuentes", detail: "Leyendo Apple Music…", isWorking: true),
            .init(title: "Analizando equivalencias", detail: longName, fraction: 0.5, isWorking: true),
            .init(title: "Aplicando lote", detail: longName, isWorking: true),
            .init(title: "Sincronización", detail: "Lectura cancelada. Se conserva la comparación anterior."),
            .init(title: "Sincronización", detail: longName),
            .init(title: "Sincronización", detail: "Comparación lista.")
        ]
    }

    func testPanelHeightStaysConstantAcrossReadAnalysisWaitAndTerminalStates() async {
        _ = NSApplication.shared
        for width: CGFloat in [700, 740, 1089] {
            let host = NSHostingView(rootView: panel(states[0], index: 0).frame(width: width))
            let expected = host.fittingSize.height
            for (index, state) in states.enumerated() {
                host.rootView = panel(state, index: index).frame(width: width)
                await settle(host)
                XCTAssertEqual(host.fittingSize.height, expected, accuracy: 1, "width=\(width), state=\(index)")
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            }
        }
    }

    func testPlaylistPopoverKeepsItsViewportWhenRowsArriveOrChangeStatus() async {
        _ = NSApplication.shared
        let first = LibraryReadProgress.PlaylistStatus(id: 0, name: longName, total: 1000)
        let host = NSHostingView(rootView: LibraryReadPlaylistDetails(playlists: [first]))
        let expected = host.fittingSize
        var many = (0..<250).map { LibraryReadProgress.PlaylistStatus(id: $0, name: longName, total: 1000) }
        many[0].state = .partial; many[0].received = 999
        host.rootView = LibraryReadPlaylistDetails(playlists: many)
        await settle(host)
        XCTAssertEqual(host.fittingSize.height, expected.height, accuracy: 1)
        XCTAssertEqual(host.fittingSize.width, expected.width, accuracy: 1)
    }

    func testReadPresentationPreservesUnknownEmptyAndPartialStates() {
        XCTAssertNil(LibraryProgressPresentation(read: .init(stage: .playlistList)).fraction)
        XCTAssertEqual(LibraryProgressPresentation(read: .init(stage: .playlistList, total: 0)).fraction, 1)
        let overflow = LibraryProgressPresentation(read: .init(stage: .savedTracks, received: 100, total: 50))
        XCTAssertEqual(overflow.fraction, 1)
        XCTAssertEqual(overflow.countText, "100 de 50")
        var partial = LibraryReadProgress.PlaylistStatus(id: 0, name: longName, total: 100)
        partial.state = .partial; partial.received = 50
        let state = LibraryProgressPresentation(read: .init(stage: .playlistTracks, received: 1, total: 1, playlists: [partial]))
        XCTAssertEqual(state.playlists.first?.state, .partial)
        XCTAssertEqual(state.playlists.first?.name, longName)
    }

    func testProgressUpdatesPreserveSearchFocusSelectionAndScroll() async throws {
        _ = NSApplication.shared
        let model = ProgressInteractionModel(presentation: states[0])
        let host = NSHostingView(rootView: ProgressInteractionView(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        await settle(host)
        let search = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(window.makeFirstResponder(search))
        let responder = try XCTUnwrap(window.firstResponder)
        scroll.contentView.scroll(to: .init(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin
        let frame = scroll.frame
        XCTAssertGreaterThan(offset.y, 0, "The fixture must actually be scrolled.")
        for state in states {
            model.presentation = state
            await settle(host)
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset.y, accuracy: 1)
            XCTAssertEqual(scroll.frame.height, frame.height, accuracy: 1)
            XCTAssertEqual(model.query, "ruta")
            XCTAssertTrue(model.selected)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func panel(_ state: LibraryProgressPresentation, index: Int) -> some View {
        LibraryProgressPanel(presentation: state) {
            Button("Revisar (\(index % 2 == 0 ? 0 : 1000))") { }
                .opacity(index % 2 == 0 ? 0 : 1)
            Button(state.isWorking ? "Detener" : "Comprobar pendientes") { }
        }
    }

    private func settle(_ view: NSView) async {
        try? await Task.sleep(nanoseconds: 10_000_000)
        view.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class ProgressInteractionModel: ObservableObject {
    @Published var presentation: LibraryProgressPresentation
    @Published var query = "ruta"
    @Published var selected = true
    init(presentation: LibraryProgressPresentation) { self.presentation = presentation }
}

private struct ProgressInteractionView: View {
    @ObservedObject var model: ProgressInteractionModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Buscar playlists", text: $model.query)
                Toggle("Incluir playlist", isOn: $model.selected)
                ForEach(0..<200, id: \.self) { Text("Playlist \($0)").frame(height: 32) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibraryProgressPanel(presentation: model.presentation) {
                Button(model.presentation.isWorking ? "Detener" : "Ver cambios") { }
            }
        }
    }
}
