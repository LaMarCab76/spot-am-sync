import SwiftUI
import UniformTypeIdentifiers
import SyncCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var selectedID: UUID?
    @ViewState private var search = ""
    @ViewState private var exportDocument: RunSummaryDocument?
    @ViewState private var showingExport = false
    @ViewState private var statusFilter = "all"

    private var runs: [RunSummary] {
        model.history.filter { (statusFilter == "all" || $0.status.rawValue == statusFilter) && (search.isEmpty || "\($0.status.displayTitle) \($0.message)".localizedCaseInsensitiveContains(search)) }
            .sorted { $0.startedAt > $1.startedAt }
    }
    private var selected: RunSummary? { runs.first { $0.id == selectedID } ?? runs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "Tu recorrido", title: "Historial de sincronizaciones", subtitle: "Consultá los resultados anteriores y exportá el resumen de cada ejecución.")
                    Button { model.refreshHistory() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Actualizar historial").accessibilityLabel("Actualizar historial").disabled(model.isBusy).padding(.top, 27)
                }
                SearchField(text: $search, prompt: "Buscar por estado o mensaje")
                Picker("Estado", selection: $statusFilter) {
                    Text("Todos").tag("all"); Text("Completadas").tag("completed"); Text("Con pendientes").tag("partial")
                    Text("Necesitan revisión").tag("failed"); Text("Canceladas").tag("cancelled"); Text("Interrumpidas").tag("interrupted")
                }.pickerStyle(.segmented)
            }.padding(28)
            if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "Tu historial empieza con la primera ejecución", message: "Los resultados completados, parciales o interrumpidos aparecerán acá para que puedas revisarlos.")
            } else if runs.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No se encontraron ejecuciones", message: "Probá con otro estado o texto del resultado.")
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(runs) { run in historyRow(run) }
                        }.padding(.leading, 24).padding(.trailing, 12).padding(.bottom, 24)
                    }.frame(minWidth: 220, idealWidth: 245, maxWidth: 310)
                    ScrollView {
                        if let selected {
                            VStack(alignment: .leading, spacing: 16) {
                                RunResultCard(summary: selected)
                                Button {
                                    do {
                                        exportDocument = try RunSummaryDocument(summary: selected)
                                        showingExport = true
                                    } catch { model.errorMessage = error.localizedDescription }
                                } label: { Label("Exportar este resumen", systemImage: "square.and.arrow.up") }
                                Text("El resumen incluye el resultado y los mensajes de esta ejecución.")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Exportar registro completo") { model.exportHistoricalRun(id: selected.id, backupOnly: false) }
                                    Button("Exportar respaldo previo") { model.exportHistoricalRun(id: selected.id, backupOnly: true) }
                                }.disabled(model.isBusy)
                                if let record = model.selectedHistoryRecord, record.id == selected.id {
                                    HStack {
                                        Button("Comprobar o preparar de nuevo") { model.retryHistoricalRun(record) }
                                        Button("Preparar propuesta para deshacer") { model.prepareUndo(record) }
                                    }.disabled(!model.canAnalyze || record.isDemo != model.isDemo)
                                    Text("Comprobar resultados inciertos solo lee el servicio. Reintentar o deshacer requiere una nueva propuesta y confirmación.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    ForEach(record.executions) { step in
                                        VStack(alignment: .leading, spacing: 7) {
                                            HStack {
                                                Text(step.operation.title).font(.callout.weight(.medium))
                                                Spacer()
                                                StatusPill(title: stateTitle(step.state), color: step.state == .verified ? SyncStyle.green : SyncStyle.coral)
                                            }
                                            Text("\(step.operation.service.name) · \(step.operation.kind.label)").font(.caption).foregroundStyle(.secondary)
                                            if let error = step.error { Text(error).font(.caption).foregroundStyle(SyncStyle.coral) }
                                        }.padding(13).background(SyncStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                                if !selected.logs.isEmpty { LogView(logs: selected.logs, title: "Mensajes de la ejecución") }
                            }.padding(.leading, 16).padding(.trailing, 28).padding(.bottom, 28)
                        }
                    }.frame(minWidth: 380)
                }
            }
        }
        .onAppear { if !model.isBusy { model.refreshHistory() } }
        .task(id: selected?.id) { if let id = selected?.id { model.loadHistoryRecord(id: id) } }
        .fileExporter(isPresented: $showingExport, document: exportDocument, contentType: .json, defaultFilename: "SpotAMSync-resumen-\(selected?.startedAt.formatted(.iso8601.year().month().day()) ?? "ejecucion")") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
    }

    private func stateTitle(_ state: ExecutionState) -> String {
        switch state {
        case .pending: return "Sin enviar"; case .applying: return "En curso"; case .verified: return "Verificada"
        case .failed: return "Falló"; case .unknown: return "Resultado incierto"; case .rejected: return "Rechazada"
        }
    }

    private func historyRow(_ run: RunSummary) -> some View {
        Button { selectedID = run.id } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: run.status.displaySymbol).foregroundStyle(run.status.displayColor)
                    Text(run.startedAt, format: .dateTime.day().month().hour().minute()).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Text(run.status.displayTitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                HStack {
                    Text("\(run.verifiedCount)/\(run.totalCount) verificadas").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if run.isDemoSummary { Label("Demo", systemImage: "flask").font(.system(size: 10)).foregroundStyle(SyncStyle.coral) }
                }
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected?.id == run.id ? SyncStyle.green.opacity(0.09) : SyncStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected?.id == run.id ? SyncStyle.green.opacity(0.4) : SyncStyle.border))
        }.buttonStyle(.plain).accessibilityAddTraits(selected?.id == run.id ? .isSelected : [])
    }
}

private struct RunSummaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(summary: RunSummary) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        data = try encoder.encode(summary)
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
