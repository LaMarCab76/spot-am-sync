import SwiftUI

/// The window's persistent activity surface, shared by the wizard and review pages.
struct SyncActivityStatusView: View {
    @ObservedObject var model: AppModel
    var prefersLibrarySync: Bool
    var review: () -> Void
    @ScaledMetric(relativeTo: .caption) private var reviewWidth = 100
    @ScaledMetric(relativeTo: .caption) private var actionWidth = 134

    private var presentation: LibraryProgressPresentation {
        if let progress = model.libraryProgress ?? model.librarySync.libraryProgress {
            return .init(read: progress)
        }
        let sync = model.librarySync
        if sync.isWorking || (!model.legacyBusy && (prefersLibrarySync || sync.library != nil)) {
            return .init(sync: sync)
        }
        return .init(title: model.isBusy ? "En curso" : "Todo a tu ritmo",
                     detail: model.displayedStatusText, isWorking: model.isBusy)
    }

    var body: some View {
        LibraryProgressPanel(presentation: presentation) {
            Button(action: review) {
                Text("Revisar (\(model.librarySync.readyDifferences.count))").monospacedDigit().lineLimit(1)
                    .frame(width: reviewWidth)
            }
                .disabled(model.librarySync.readyDifferences.isEmpty)
                .opacity(model.librarySync.readyDifferences.isEmpty ? 0 : 1)
                .accessibilityHidden(model.librarySync.readyDifferences.isEmpty)
            Button {
                if model.isBusy { model.cancel() }
                else if model.canResume { model.resume() }
                else { review() }
            } label: {
                Text(model.isBusy ? "Detener" : model.canResume ? "Comprobar pendientes" : "Ver cambios")
                    .lineLimit(1).frame(width: actionWidth)
            }
        }
    }
}

extension LibraryProgressPresentation {
    @MainActor init(sync: LibrarySyncCoordinator) {
        if let read = sync.libraryProgress {
            self.init(read: read)
        } else {
            let title = sync.isReadingSources ? "Leyendo fuentes" : sync.isAnalyzing ? "Analizando equivalencias" :
                sync.isApplying ? "Aplicando lote" : sync.isWorking ? "Buscando alternativas" : "Sincronización"
            self.init(title: title, detail: sync.statusText,
                      fraction: sync.isAnalyzing && !sync.isReadingSources ? sync.progress : nil,
                      isWorking: sync.isWorking)
        }
    }
}
