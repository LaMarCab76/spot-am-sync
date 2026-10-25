import SwiftUI
import SyncCore

private enum ManualChecklistFilter: String, CaseIterable, Identifiable {
    case missing = "Faltantes"
    case review = "Por revisar"
    case marked = "Marcadas por vos"
    case present = "Presentes en XML"
    case all = "Todas"

    var id: String { rawValue }

    func includes(_ item: ManualChecklistItem, marked: Bool) -> Bool {
        switch self {
        case .missing: return item.evidence == .missing && !marked
        case .review: return item.evidence == .review && !marked
        case .marked: return item.evidence != .present && marked
        case .present: return item.evidence == .present
        case .all: return true
        }
    }
}

struct ManualChecklistView: View {
    @ObservedObject var manual: ManualChecklistModel
    @EnvironmentObject private var model: AppModel
    @ViewState private var search = ""
    @ViewState private var filter: ManualChecklistFilter = .missing
    @ViewState private var reviewing: ManualChecklistItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(eyebrow: "Checklist manual", title: "Agregá tu música, a tu ritmo",
                            subtitle: "Compará Spotify con una exportación de Música y marcá las canciones que agregues manualmente. Este flujo no necesita membresía Apple Developer.")
                if manual.isDemo {
                    Label("Demostración · Datos ficticios; tu lista real sigue guardada.", systemImage: "flask")
                        .font(.callout).foregroundStyle(SyncStyle.coral)
                }
                workflow
                feedback
                if let report = manual.report {
                    reportDetails(report)
                    checklist(report)
                } else if let library = manual.library {
                    libraryDetails(library)
                    EmptyState(symbol: "arrow.clockwise", title: "Actualizá desde Spotify",
                               message: "Este XML todavía no tiene un checklist. Conectá Spotify desde Conexiones y elegí Actualizar desde Spotify para compararlo.")
                } else if manual.isHydrated {
                    EmptyState(symbol: "doc.badge.plus", title: "Empezá con tu biblioteca de Música",
                               message: "Importá el archivo XML o probá la demostración local para conocer el checklist.")
                }
            }
            .padding(28)
        }
        .sheet(item: $reviewing) { item in
            let result = manual.candidateResults[item.id]
            let choice = manual.choices[item.id]
            let rejected = Set(choice?.rejectedIDs ?? [])
            TrackCandidateReview(source: item.track, service: .appleMusic,
                                 candidates: (result?.candidates ?? item.candidates).filter { !rejected.contains($0.id) },
                                 selected: choice?.selected, notes: result?.notes ?? ["Buscá para ampliar las coincidencias del XML. Las opciones online son referencias para elegir; no confirman presencia."],
                                 busy: model.isBusy, publicSearch: model.accounts[.appleMusic] == nil,
                                 search: { model.searchManualTrack(itemID: item.id, query: $0) },
                                 choose: { manual.choose(itemID: item.id, candidate: $0) },
                                 reject: { manual.rejectCandidate(itemID: item.id, candidate: $0) },
                                 pending: { manual.choose(itemID: item.id, candidate: nil, decision: .pending) },
                                 omit: { manual.choose(itemID: item.id, candidate: nil, decision: .omitted) },
                                 restore: { manual.restoreCandidates(itemID: item.id) }, cancel: { manual.cancel() })
        }
    }

    @ViewBuilder
    private var workflow: some View {
        if manual.report != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { workflowButtons }
                VStack(alignment: .leading, spacing: 10) { workflowButtons }
            }.disabled(model.isBusy)
        } else {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("De Spotify a tu biblioteca").font(.headline)
                    workflowInstructions
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { workflowButtons }
                        VStack(alignment: .leading, spacing: 10) { workflowButtons }
                    }.disabled(model.isBusy)
                    if !manual.isDemo, manual.library != nil, !model.canGenerateManualChecklist, !manual.isBusy {
                        Text("Para actualizar, Spotify debe estar conectado a una cuenta real y las otras operaciones deben haber terminado. El checklist guardado se puede consultar sin conexión.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var workflowInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            instruction("1", "Conectá Spotify desde Conexiones.")
            instruction("2", "En Música, elegí Archivo > Biblioteca > Exportar biblioteca… e importá ese XML.")
            instruction("3", "Generá la lista, buscá cada canción en Apple Music y marcá lo que agregues.")
        }
    }

    @ViewBuilder
    private var workflowButtons: some View {
        if manual.isDemo {
            Button("Volver a mi checklist", systemImage: "arrow.uturn.backward") { manual.restoreSavedState() }
                .disabled(manual.isBusy)
        } else {
            Button(manual.library == nil ? "Importar XML" : "Reimportar XML", systemImage: "square.and.arrow.down") {
                manual.importXML()
            }.disabled(manual.isBusy || !manual.isHydrated)
            Button(manual.library != nil && manual.report == nil ? "Actualizar desde Spotify" : manual.report == nil ? "Generar checklist" : "Actualizar desde Spotify",
                   systemImage: "arrow.clockwise") { model.generateManualChecklist() }
                .buttonStyle(.borderedProminent)
                .disabled(manual.isBusy || !manual.isHydrated || manual.library == nil || !model.canGenerateManualChecklist)
            Button("Ver ejemplo", systemImage: "flask") { manual.loadDemo() }
                .disabled(manual.isBusy || !manual.isHydrated)
        }
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(number).font(.caption.weight(.bold)).foregroundStyle(SyncStyle.green)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let progress = manual.libraryProgress { LibraryReadProgressView(progress: progress) }
        HStack(spacing: 9) {
            if manual.libraryProgress == nil {
                if manual.isBusy { ProgressView().controlSize(.small) }
                Text(manual.statusText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if manual.canCancel { Button("Cancelar") { manual.cancel() } }
        }
        .accessibilityElement(children: .contain)
        if let error = manual.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Notice(title: "No se pudo completar la acción", message: error,
                       symbol: "exclamationmark.triangle", color: SyncStyle.coral)
                if manual.isHydrated {
                    Button("Cerrar aviso") { manual.dismissError() }.controlSize(.small)
                }
            }
        }
        if manual.hasUnsavedChanges, !manual.isBusy {
            HStack(alignment: .top, spacing: 12) {
                Notice(title: "Cambios sin guardar", message: "Los cambios de tu checklist real siguen en memoria. Reintentá el guardado antes de cerrar la app.", symbol: "externaldrive.badge.exclamationmark", color: SyncStyle.coral)
                Button("Reintentar guardado") { manual.retrySave() }.disabled(manual.isBusy || model.isBusy)
            }
        }
        if !manual.isHydrated, !manual.isBusy {
            Button("Reintentar carga", systemImage: "arrow.clockwise") { manual.restoreSavedState() }
                .disabled(model.isBusy)
        }
    }

    private func libraryDetails(_ library: ManualMusicLibrary) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 9) {
                Label(library.fileName, systemImage: "doc.text").font(.headline).textSelection(.enabled)
                Text("\(library.tracks.count) canciones en el XML · Importado \(dateText(library.importedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(library.exportedAt.map { "Fecha de exportación: \(dateText($0))" }
                     ?? "El XML no indica su fecha de exportación; la fecha de importación no garantiza que esté actualizado.")
                    .font(.caption).foregroundStyle(.secondary)
                if !library.complete {
                    Notice(title: "Exportación incompleta", message: "Los datos que faltan no prueban ausencia. Revisá las advertencias antes de agregar canciones.", symbol: "exclamationmark.triangle", color: SyncStyle.coral)
                }
                warnings(library.warnings)
            }
        }
    }

    private func reportDetails(_ report: ManualChecklist) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 11) {
                Text(report.sourceAccountName).font(.headline).textSelection(.enabled)
                Text("Spotify leído: \(dateText(report.sourceFetchedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("XML: \(report.fileName) · Importado: \(dateText(report.importedAt))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Marcá después de agregar cada canción en Música. Las casillas guardan tu avance; no modifican Apple Music. La presencia se compara contra el XML importado.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let account = model.accounts[.spotify], !model.isDemo, !report.isDemo, account.id != report.sourceAccountID {
                    Text("Esta lista corresponde a otra cuenta de Spotify. Actualizá para comparar la cuenta conectada ahora.")
                        .font(.caption).foregroundStyle(SyncStyle.coral)
                }
                DisclosureGroup("Fechas, cobertura y advertencias") {
                    VStack(alignment: .leading, spacing: 9) {
                        workflowInstructions
                        Text(report.exportedAt.map { "Exportado: \(dateText($0))" } ?? "Fecha de exportación desconocida.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("El XML puede estar desactualizado. Para comprobar lo agregado después, exportá Música otra vez y reimportá el XML. Al reiniciar la app también necesitás actualizar la lectura de Spotify.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        warnings(report.warnings)
                    }.padding(.top, 8)
                }.font(.callout)
            }
        }
    }

    @ViewBuilder
    private func warnings(_ messages: [String]) -> some View {
        if !messages.isEmpty {
            DisclosureGroup("Advertencias · \(messages.count)") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 8)
            }.font(.callout)
        }
    }

    private func checklist(_ report: ManualChecklist) -> some View {
        let counts = counts(for: report)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = report.items.filter { item in
            filter.includes(item, marked: manual.markedIDs.contains(item.id))
                && (query.isEmpty || "\(item.track.title) \(item.track.artist) \(item.track.albumTitle)"
                    .localizedStandardContains(query))
        }
        return VStack(alignment: .leading, spacing: 15) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                countButton(.missing, count: counts.missing)
                countButton(.review, count: counts.review)
                countButton(.marked, count: counts.marked)
                countButton(.present, count: counts.present)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    filterPicker
                    SearchField(text: $search, prompt: "Canción, artista o álbum").frame(minWidth: 230)
                }
                VStack(alignment: .leading, spacing: 10) {
                    filterPicker
                    SearchField(text: $search, prompt: "Canción, artista o álbum")
                }
            }
            Text("\(items.count) de \(report.items.count) canciones · Faltantes y Por revisar excluyen tus marcas.")
                .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                EmptyState(symbol: "checklist", title: "Sin canciones en esta vista",
                           message: "Probá Todas u otro filtro. Las marcas manuales se consultan en Marcadas por vos.")
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(items) { item in
                        ManualChecklistRow(item: item, marked: manual.markedIDs.contains(item.id),
                                           choice: manual.choices[item.id],
                                           canMark: manual.isHydrated && !manual.isBusy && !model.isBusy,
                                           mark: { manual.setMarked(itemID: item.id, marked: $0, scopeID: report.scopeID) },
                                           search: { manual.searchInAppleMusic(manual.choices[item.id]?.selected ?? item.track) },
                                           review: { reviewing = item })
                    }
                }
            }
        }
    }

    private var filterPicker: some View {
        Picker("Mostrar", selection: $filter) {
            ForEach(ManualChecklistFilter.allCases) { Text($0.rawValue).tag($0) }
        }.frame(width: 245)
    }

    private func countButton(_ option: ManualChecklistFilter, count: Int) -> some View {
        Button { filter = option } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(count)").font(.title2.weight(.semibold)).monospacedDigit()
                Text(option.rawValue).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .foregroundStyle(filter == option ? SyncStyle.green : .primary)
            .background(filter == option ? SyncStyle.green.opacity(0.08) : SyncStyle.surface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(filter == option ? SyncStyle.green : SyncStyle.border))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.rawValue): \(count) \(count == 1 ? "canción" : "canciones")")
        .accessibilityAddTraits(filter == option ? .isSelected : [])
    }

    private func counts(for report: ManualChecklist) -> (missing: Int, review: Int, marked: Int, present: Int) {
        var result = (missing: 0, review: 0, marked: 0, present: 0)
        for item in report.items {
            if item.evidence == .present { result.present += 1 }
            else if manual.markedIDs.contains(item.id) { result.marked += 1 }
            else if item.evidence == .missing { result.missing += 1 }
            else { result.review += 1 }
        }
        return result
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "es_AR")))
    }
}

private struct ManualChecklistRow: View {
    let item: ManualChecklistItem
    let marked: Bool
    let choice: ManualTrackChoice?
    let canMark: Bool
    let mark: (Bool) -> Void
    let search: () -> Void
    let review: () -> Void

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.track.title).font(.headline).textSelection(.enabled)
                        Text(item.track.artist).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    StatusPill(title: statusTitle, symbol: item.evidence == .present ? "checkmark.seal" : marked ? "checkmark.square" : "magnifyingglass",
                               color: item.evidence == .review && !marked ? SyncStyle.coral : SyncStyle.green)
                }
                ManualChecklistTrackMetadata(track: item.track)
                if let selected = choice?.selected {
                    Text("Elegida por vos: \(selected.title) · \(selected.artist) · \(selected.albumTitle)")
                        .font(.callout).foregroundStyle(SyncStyle.green).fixedSize(horizontal: false, vertical: true)
                    Text(choice?.origin == .xml ? "Equivalencia elegida en el XML. La elección se conserva separada de la verificación automática."
                         : "Referencia online guardada. No confirma disponibilidad actual ni presencia en el XML.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if choice?.decision == .omitted {
                    Text("Omitida por vos. Podés volver a elegir un equivalente.").font(.caption).foregroundStyle(.secondary)
                }
                if !item.reason.isEmpty {
                    Text(item.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !item.locations.isEmpty {
                    Label("En Spotify: \(item.locations.joined(separator: " · "))", systemImage: "music.note.list")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !item.candidates.isEmpty {
                    DisclosureGroup("\(item.candidates.count) coincidencias en el XML · Revisar edición") {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(item.candidates.enumerated()), id: \.offset) { _, candidate in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(candidate.title).font(.callout.weight(.medium))
                                    Text(candidate.artist).font(.caption).foregroundStyle(.secondary)
                                    ManualChecklistTrackMetadata(track: candidate)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 10)
                    }.font(.caption)
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { rowActions }
                    VStack(alignment: .leading, spacing: 12) { rowActions }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var rowActions: some View {
        if item.evidence != .present {
            Toggle("Marcar como agregada", isOn: Binding(get: { marked }, set: mark))
                .toggleStyle(.checkbox).disabled(!canMark)
                .accessibilityLabel("Marcar como agregada: \(item.track.title), \(item.track.artist)")
                .accessibilityHint("Confirmación local reversible. No agrega canciones ni confirma su presencia en el XML.")
                .help("Marcá después de agregarla vos. Podés quitar la marca en cualquier momento.")
        } else {
            Label("Confirmada en esta exportación", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Buscar en Apple Music", systemImage: "magnifyingglass", action: search)
            .controlSize(.small)
            .accessibilityLabel("Buscar en Apple Music: \(item.track.title), \(item.track.artist)")
            .help("Abre una búsqueda de título, artista y álbum en music.apple.com.")
        Button("Elegir equivalente", systemImage: "arrow.triangle.branch", action: review).disabled(!canMark)
    }

    private var statusTitle: String {
        if item.evidence == .present { return "Presente en XML" }
        if marked { return "Marcada por vos" }
        return item.evidence == .missing ? "Falta en el XML" : "Por revisar"
    }
}

private struct ManualChecklistTrackMetadata: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 12) {
                Label(track.albumTitle.isEmpty ? "Álbum no informado" : track.albumTitle, systemImage: "square.stack")
                    .fixedSize(horizontal: false, vertical: true)
                Text(track.durationMS > 0
                     ? "\(track.durationMS / 60_000):\(String(format: "%02d", track.durationMS / 1000 % 60))"
                     : "Duración no informada")
                    .monospacedDigit().fixedSize()
            }
            HStack(spacing: 8) {
                Text(track.explicit.map { $0 ? "Explícita" : "Sin contenido explícito" }
                     ?? "Contenido explícito no informado")
                if track.isLocal { Text("Archivo local") }
                if !track.available { Text("No disponible") }
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
