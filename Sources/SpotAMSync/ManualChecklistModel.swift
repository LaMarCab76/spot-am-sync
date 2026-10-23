import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import SyncCore

@MainActor
final class ManualChecklistModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isHydrated = false
    @Published private(set) var library: ManualMusicLibrary?
    @Published private(set) var report: ManualChecklist?
    @Published private(set) var markedIDs: Set<String> = []
    @Published private(set) var isDemo = false
    @Published private(set) var canCancel = false
    @Published private(set) var statusText = "Cargando el checklist guardado…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasUnsavedChanges = false

    private var store: ManualChecklistStore?
    private var realState = ManualChecklistState()
    private var realSource: LibrarySnapshot?
    private var demoMarks: [String: Set<String>] = [:]
    private var workTask: Task<Void, Never>?
    private var importPanel: NSOpenPanel?

    init() {
        restoreSavedState()
    }

    /// Loading and every write share this task slot. No mutation can race hydration
    /// or a previous save, and restoring waits for any failed write to be retried.
    func restoreSavedState() {
        guard !isBusy else { return }
        begin("Cargando el checklist guardado…", cancellable: false)
        workTask = Task {
            defer { finish() }
            do {
                if store == nil {
                    let base: URL
                    if let override = ProcessInfo.processInfo.environment["SPOTAM_DATA_DIR"], !override.isEmpty {
                        base = URL(fileURLWithPath: override, isDirectory: true)
                    } else {
                        base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
                            .appendingPathComponent("SpotAMSync", isDirectory: true)
                    }
                    store = ManualChecklistStore(url: base.appendingPathComponent("manual-checklist.json"))
                }
                guard let store else { return }
                if hasUnsavedChanges {
                    guard await persistRealState() else { return }
                }
                isHydrated = false
                var saved = try await store.load() ?? ManualChecklistState()
                // A stable library ID can survive a re-export. Check the exact
                // import too, so an earlier report never describes a newer XML.
                if let savedReport = saved.report {
                    if savedReport.isDemo || saved.library?.id != savedReport.libraryID
                        || saved.library?.importedAt != savedReport.importedAt
                        || saved.library?.fileName != savedReport.fileName {
                        saved.report = nil
                    }
                }
                realState = saved
                realSource = nil
                isDemo = false
                isHydrated = true
                showRealState()
                statusText = report != nil
                    ? "Checklist recuperado. Podés continuar sin conexión con los datos guardados."
                    : library != nil ? "XML recuperado. Actualizá desde Spotify para generar el checklist."
                    : "Importá tu biblioteca de Música para empezar."
            } catch {
                errorMessage = "No se pudo recuperar el checklist guardado. Reintentá la carga; el archivo no se reemplazó."
                statusText = "No se pudo cargar el estado guardado."
            }
        }
    }

    func importXML() {
        guard isHydrated, !isBusy, !isDemo else { return }
        begin("Elegí la biblioteca XML exportada desde Música…", cancellable: true)
        let panel = NSOpenPanel()
        panel.title = "Importar biblioteca de Música"
        panel.message = "En Música: Archivo > Biblioteca > Exportar biblioteca… Guardá el archivo XML e importalo aquí."
        panel.allowedContentTypes = [.xml]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Importar XML"
        importPanel = panel
        workTask = Task {
            defer { importPanel = nil; finish() }
            do {
                let response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard response == .OK, let url = panel.url else {
                    statusText = "Importación cancelada."
                    return
                }
                importPanel = nil
                statusText = "Leyendo el XML de Música…"
                let imported = try await Self.inBackground {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    try Task.checkCancellation()
                    return try MusicXMLImporter.parse(data, fileName: url.lastPathComponent)
                }
                var updatedReport: ManualChecklist?
                if let source = realSource {
                    statusText = "Comparando el nuevo XML con la última lectura de Spotify…"
                    updatedReport = try await Self.inBackground {
                        ManualChecklistPlanner.make(source: source, library: imported)
                    }
                }
                try Task.checkCancellation()
                realState.library = imported
                realState.report = updatedReport
                showRealState()
                let saved = await persistRealState()
                statusText = saved
                    ? updatedReport != nil
                        ? "Checklist recalculado con el nuevo XML y la última lectura de Spotify."
                        : "XML importado. Actualizá desde Spotify para generar el checklist."
                    : "XML importado en memoria. Hay cambios pendientes de guardar."
            } catch is CancellationError {
                statusText = "Importación cancelada. Se conserva el checklist anterior."
            } catch {
                errorMessage = "No se pudo importar la biblioteca. Elegí un XML exportado desde Música. \(error.localizedDescription)"
                statusText = "La importación no se completó. Se conserva el estado anterior."
            }
        }
    }

    func generate(isDemo: Bool, fetch: @escaping @MainActor () async throws -> LibrarySnapshot) {
        // The demo never calls a provider, even if a caller supplies one.
        if isDemo { loadDemo(); return }
        guard isHydrated, !isBusy, !self.isDemo else { return }
        guard let library = realState.library else {
            errorMessage = "Importá primero el XML de tu biblioteca de Música."
            return
        }
        begin("Leyendo tu biblioteca de Spotify…", cancellable: true)
        workTask = Task {
            defer { finish() }
            do {
                let source = try await fetch()
                try Task.checkCancellation()
                guard source.account.service == .spotify else {
                    errorMessage = "El checklist necesita una lectura de Spotify."
                    statusText = "No se generó un nuevo checklist."
                    return
                }
                statusText = "Comparando Spotify con la exportación de Música…"
                let updatedReport = try await Self.inBackground {
                    ManualChecklistPlanner.make(source: source, library: library)
                }
                try Task.checkCancellation()
                realSource = source
                realState.report = updatedReport
                showRealState()
                let saved = await persistRealState()
                statusText = saved ? "Checklist actualizado. Las marcas son confirmaciones tuyas."
                    : "Checklist actualizado en memoria. Hay cambios pendientes de guardar."
            } catch is CancellationError {
                statusText = "Actualización cancelada. Se conserva el checklist anterior."
            } catch {
                if Task.isCancelled {
                    statusText = "Actualización cancelada. Se conserva el checklist anterior."
                } else {
                    errorMessage = "No se pudo actualizar desde Spotify. Revisá la conexión en Conexiones y volvé a intentar."
                    statusText = "El checklist anterior sigue disponible con su fecha original."
                }
            }
        }
    }

    func loadDemo() {
        guard isHydrated, !isBusy else { return }
        begin("Preparando el ejemplo local…", cancellable: true)
        workTask = Task {
            defer { finish() }
            do {
                let result = try await Self.inBackground { () throws -> (ManualMusicLibrary, ManualChecklist) in
                    let snapshots = DemoFixtures.snapshots()
                    guard var spotify = snapshots.first(where: { $0.account.service == .spotify }),
                          let apple = snapshots.first(where: { $0.account.service == .appleMusic }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    spotify.account.id = "manual-demo:spotify"
                    let library = ManualMusicLibrary(id: "manual-demo:apple", fileName: "Biblioteca de ejemplo.xml",
                                                     importedAt: apple.fetchedAt, exportedAt: apple.fetchedAt,
                                                     tracks: apple.allTracks)
                    return (library, ManualChecklistPlanner.make(source: spotify, library: library, isDemo: true))
                }
                try Task.checkCancellation()
                isDemo = true
                library = result.0
                report = result.1
                markedIDs = demoMarks[result.1.scopeID] ?? []
                statusText = "Demostración local. Las marcas del ejemplo duran durante esta sesión."
            } catch is CancellationError {
                statusText = "Carga del ejemplo cancelada."
            } catch {
                errorMessage = "No se pudo preparar el ejemplo local."
            }
        }
    }

    func setMarked(itemID: String, marked: Bool, scopeID: String) {
        guard isHydrated, !isBusy, let report, report.scopeID == scopeID,
              let item = report.items.first(where: { $0.id == itemID }), item.evidence != .present,
              markedIDs.contains(itemID) != marked else { return }
        var updated = markedIDs
        if marked { updated.insert(itemID) } else { updated.remove(itemID) }
        markedIDs = updated
        if isDemo {
            demoMarks[scopeID] = updated
            statusText = marked ? "Marcada en el ejemplo local." : "Marca quitada del ejemplo local."
            return
        }
        // Keep other scopes and older item IDs: editing an edition must not move
        // a confirmation to another item, account, or Music library.
        realState.markedIDsByScope[scopeID] = updated
        begin("Guardando la marca local…", cancellable: false)
        workTask = Task {
            defer { finish() }
            let saved = await persistRealState()
            statusText = saved ? "Marca local guardada. No confirma presencia en la exportación."
                : "La marca está en memoria y todavía no se pudo guardar."
        }
    }

    func retrySave() {
        guard isHydrated, !isBusy, hasUnsavedChanges else { return }
        begin("Guardando el checklist…", cancellable: false)
        workTask = Task {
            defer { finish() }
            if await persistRealState() { statusText = "Checklist guardado en este equipo." }
        }
    }

    func cancel() {
        guard isBusy, canCancel else { return }
        canCancel = false
        statusText = "Cancelando…"
        workTask?.cancel()
        importPanel?.cancel(nil)
    }

    func dismissError() { errorMessage = nil }

    static func searchURL(for track: Track) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.apple.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "term", value: [track.title, track.artist, track.albumTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " "))]
        // Preserve literal plus signs for servers that decode queries as forms.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func searchInAppleMusic(_ track: Track) {
        guard let url = Self.searchURL(for: track), NSWorkspace.shared.open(url) else {
            errorMessage = "No se pudo abrir la búsqueda de Apple Music en este equipo."
            return
        }
    }

    private func begin(_ message: String, cancellable: Bool) {
        isBusy = true
        canCancel = cancellable
        statusText = message
        errorMessage = nil
    }

    private func finish() {
        canCancel = false
        isBusy = false
        workTask = nil
    }

    private func showRealState() {
        library = realState.library
        report = realState.report
        markedIDs = realState.report.flatMap { realState.markedIDsByScope[$0.scopeID] } ?? []
    }

    @discardableResult
    private func persistRealState() async -> Bool {
        canCancel = false
        hasUnsavedChanges = true
        guard let store else {
            errorMessage = "El almacenamiento no está disponible. Los cambios siguen en memoria."
            return false
        }
        do {
            try await store.save(realState)
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = "No se pudo guardar el checklist. Los cambios siguen en memoria; reintentá el guardado antes de cerrar."
            return false
        }
    }

    /// Parsing and matching can be expensive for large libraries. Keep the main
    /// actor responsive, and discard results if cancellation arrived meanwhile.
    private nonisolated static func inBackground<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try operation()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
