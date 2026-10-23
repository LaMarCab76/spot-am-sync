import SwiftUI
import SyncCore

private enum EntityFilter: String, CaseIterable, Identifiable {
    case all = "Todo", playlists = "Playlists", tracks = "Canciones", albums = "Álbumes"
    var id: String { rawValue }
}

private enum AvailabilityFilter: String, CaseIterable, Identifiable {
    case all = "Todos los cambios", available = "Disponibles", blocked = "Bloqueados", destructive = "Bajas y reemplazos"
    var id: String { rawValue }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    var navigate: (AppDestination) -> Void
    @ViewState private var search = ""
    @ViewState private var entity: EntityFilter = .all
    @ViewState private var availability: AvailabilityFilter = .all
    @ViewState private var serviceFilter = "all"
    @ViewState private var showIssues = true
    @ViewState private var approval: ApprovalRequest?

    private var filtered: [SyncOperation] {
        (model.plan?.operations ?? []).filter { operation in
            (entity == .all || operation.kind.entityTitle == entity.rawValue)
            && (serviceFilter == "all" || operation.service.rawValue == serviceFilter)
            && (availability == .all || availability == .available && operation.blockedReason == nil
                || availability == .blocked && operation.blockedReason != nil || availability == .destructive && operation.kind.isDestructive)
            && (search.isEmpty || [operation.title, operation.detail, operation.kind.label, operation.service.name, operation.blockedReason ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private var selected: [SyncOperation] { model.selectedOperations.filter { $0.blockedReason == nil } }
    private var isReviewing: Bool { if case .review = model.phase { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            if let plan = model.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top, spacing: 16) {
                            PageHeading(eyebrow: "La decisión es tuya", title: "Revisá cada cambio", subtitle: "Marcá lo que querés aplicar. Las operaciones bloqueadas quedan fuera de la selección.")
                            Button { navigate(.matches) } label: { Label("Coincidencias", systemImage: "arrow.triangle.branch") }.padding(.top, 25)
                        }
                        ModeSelectionView(compact: true)
                        if !plan.snapshots.allSatisfy(\.complete) {
                            Notice(title: "Falta completar la lectura", message: "Podés revisar las diferencias conocidas. Para aplicar cambios necesitamos un inventario completo de ambas bibliotecas y un respaldo verificable. Volvé a analizar cuando se resuelvan los errores de lectura.", symbol: "exclamationmark.shield", color: SyncStyle.coral)
                        }
                        if !plan.issues.isEmpty {
                            DisclosureGroup(isExpanded: $showIssues) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(plan.issues) { issue in
                                        HStack(alignment: .top, spacing: 9) {
                                            Image(systemName: "exclamationmark.circle").foregroundStyle(SyncStyle.coral)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(issue.title).font(.callout.weight(.semibold))
                                                Text(issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                                if let service = issue.service { Text(service.name).font(.caption2).foregroundStyle(.secondary) }
                                            }
                                        }
                                    }
                                }.padding(.top, 10)
                            } label: {
                                Label("\(plan.issues.count) observaciones del análisis", systemImage: "exclamationmark.bubble")
                                    .font(.callout.weight(.semibold)).foregroundStyle(SyncStyle.coral)
                            }.padding(15).background(SyncStyle.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        filterBar
                        HStack {
                            Text("\(filtered.count) de \(plan.operations.count) cambios").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Seleccionar disponibles visibles") {
                                model.selectedOperationIDs.formUnion(filtered.filter { $0.blockedReason == nil }.map(\.id))
                            }.disabled(model.isBusy || filtered.allSatisfy { $0.blockedReason != nil })
                            Button("Quitar selección") { model.selectedOperationIDs.removeAll() }
                                .disabled(model.isBusy || model.selectedOperationIDs.isEmpty)
                        }.controlSize(.small)
                        if plan.operations.isEmpty {
                            EmptyState(symbol: "checkmark.circle", title: "Sin cambios propuestos", message: "El plan actual no contiene operaciones. Revisá las observaciones y las coincidencias pendientes antes de dar la revisión por terminada.")
                        } else if filtered.isEmpty {
                            EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No hay coincidencias con estos filtros", message: "Probá con otro texto o mostrá todos los tipos de cambio.")
                            Button("Restablecer filtros") { search = ""; entity = .all; availability = .all; serviceFilter = "all" }
                                .frame(maxWidth: .infinity)
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { operation in OperationRow(operation: operation) }
                            }
                        }
                    }.padding(28)
                }
                approvalBar(plan)
            } else {
                VStack {
                    EmptyState(symbol: "checklist", title: "Primero, analizá tus bibliotecas", message: "Acá vas a ver los cambios propuestos, sus destinos y las acciones que necesitan tu atención.")
                    Button("Ir al resumen") { navigate(.overview) }.buttonStyle(.borderedProminent).padding(.bottom, 50)
                }
            }
        }
        .sheet(item: $approval) { request in ApprovalSheet(request: request) }
    }

    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Tipo de contenido", selection: $entity) {
                    ForEach(EntityFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }.pickerStyle(.segmented)
                SearchField(text: $search, prompt: "Buscar cambios").frame(minWidth: 180, maxWidth: 290)
            }
            HStack {
                Picker("Destino", selection: $serviceFilter) {
                    Text("Ambos servicios").tag("all")
                    ForEach(MusicService.allCases) { service in Text(service.name).tag(service.rawValue) }
                }.frame(maxWidth: 270)
                Picker("Mostrar", selection: $availability) {
                    ForEach(AvailabilityFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }.frame(maxWidth: 290)
                Spacer(minLength: 0)
            }.pickerStyle(.menu).font(.callout)
        }
    }

    private func approvalBar(_ plan: SyncPlan) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(selected.count) cambios seleccionados").font(.callout.weight(.semibold)).monospacedDigit()
                    let destructive = selected.filter { $0.kind.isDestructive }.count
                    let hidden = selected.filter { selection in !filtered.contains { $0.id == selection.id } }.count
                    Text(destructive > 0 ? "Incluyen \(destructive) bajas o reemplazos" : "Sin bajas ni reemplazos seleccionados")
                        .font(.caption).foregroundStyle(destructive > 0 ? SyncStyle.coral : .secondary)
                    if hidden > 0 { Text("\(hidden) seleccionados fuera de los filtros actuales").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { approval = ApprovalRequest(plan: plan, operations: selected, isDemo: model.isDemo) } label: {
                    Label(model.isDemo ? "Revisar simulación" : "Revisar y confirmar", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canExecute || !isReviewing)
            }.padding(.horizontal, 28).padding(.vertical, 17).background(SyncStyle.surface)
        }
    }
}

private struct OperationRow: View {
    @EnvironmentObject private var model: AppModel
    let operation: SyncOperation
    @ViewState private var expanded = false
    private var isSelected: Bool { model.selectedOperationIDs.contains(operation.id) && operation.blockedReason == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            if operation.blockedReason == nil {
                Toggle("Seleccionar \(operation.kind.label): \(operation.title)", isOn: Binding(get: { isSelected }, set: { value in
                    guard !model.isBusy, operation.blockedReason == nil else { return }
                    if value { model.selectedOperationIDs.insert(operation.id) } else { model.selectedOperationIDs.remove(operation.id) }
                }))
                .toggleStyle(.checkbox).labelsHidden().disabled(model.isBusy).padding(.top, 4)
            } else {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).frame(width: 14).padding(.top, 5)
            }
            Image(systemName: operation.kind.symbol)
                .font(.system(size: 16)).foregroundStyle(operation.kind.isDestructive ? SyncStyle.coral : SyncStyle.green)
                .frame(width: 32, height: 32).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(operation.title).font(.callout.weight(.semibold)).textSelection(.enabled)
                        Text("\(operation.kind.label) · \(operation.service.name)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if operation.blockedReason != nil { StatusPill(title: "Bloqueado", symbol: "lock", color: .secondary) }
                    else if operation.kind.isDestructive { StatusPill(title: operation.kind.isRemoval ? "Baja" : "Reemplazo", symbol: "exclamationmark.triangle", color: SyncStyle.coral) }
                }
                if !operation.detail.isEmpty { Text(operation.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let explanation = operation.kind.destructiveExplanation {
                    Text(explanation).font(.caption).foregroundStyle(SyncStyle.coral).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = operation.blockedReason {
                    Label { Text(reason).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                        .font(.caption).foregroundStyle(.secondary).padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
                if !operation.tracks.isEmpty || !operation.albums.isEmpty || operation.beforeTrackIDs != nil {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 7) {
                            if let previous = operation.beforeTrackIDs, operation.kind == .replacePlaylistTracks {
                                Text("Contenido anterior: \(previous.count) canciones · Propuesto: \(operation.tracks.count)")
                                    .font(.caption).foregroundStyle(SyncStyle.coral)
                            }
                            ForEach(Array(operation.tracks.enumerated()), id: \.offset) { index, track in
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(minWidth: 19, alignment: .trailing)
                                    Text(track.title)
                                    Text(track.artist).foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }.font(.caption)
                            }
                            ForEach(Array(operation.albums.enumerated()), id: \.offset) { _, album in
                                Label("\(album.title) · \(album.artist)", systemImage: "square.stack").font(.caption)
                            }
                        }.padding(.top, 7)
                    } label: {
                        Text("Ver contenido · \(operation.tracks.count) canciones · \(operation.albums.count) álbumes").font(.caption)
                    }
                }
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? SyncStyle.green.opacity(0.05) : SyncStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? SyncStyle.green.opacity(0.35) : SyncStyle.border))
    }
}

private struct ApprovalRequest: Identifiable {
    let id: UUID
    let plan: SyncPlan
    let operations: [SyncOperation]
    let isDemo: Bool
    init(plan: SyncPlan, operations: [SyncOperation], isDemo: Bool) {
        self.id = UUID(); self.plan = plan; self.operations = operations; self.isDemo = isDemo
    }
}

private struct ApprovalSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: ApprovalRequest
    @ViewState private var acceptsDestructive = false
    private var destructive: [SyncOperation] { request.operations.filter { $0.kind.isDestructive } }
    private var selectionIsCurrent: Bool {
        model.plan?.id == request.plan.id && model.plan?.mode == request.plan.mode
            && Set(model.selectedOperations.map(\.id)) == Set(request.operations.map(\.id))
            && request.operations.allSatisfy { old in model.plan?.operations.contains(old) == true && old.blockedReason == nil }
            && model.isDemo == request.isDemo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: request.isDemo ? "flask" : "checkmark.shield")
                    .font(.system(size: 28)).foregroundStyle(SyncStyle.green)
                PageHeading(eyebrow: "Última revisión", title: request.isDemo ? "Confirmá la simulación" : "Confirmá tus cambios", subtitle: request.isDemo ? "Se usarán datos de ejemplo. Esta ejecución no representa escrituras reales en Spotify ni Apple Music." : "Se aplicarán solamente las operaciones seleccionadas a las bibliotecas indicadas.")
                HStack {
                    Text(request.plan.mode.title).font(.callout.weight(.semibold))
                    Spacer()
                    StatusPill(title: "\(request.operations.count) operaciones", color: SyncStyle.green)
                }
            }.padding(26)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(MusicService.allCases) { service in
                        let operations = request.operations.filter { $0.service == service }
                        if !operations.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { ServiceMark(service: service, size: 26); Text("Destino: \(service.name)").font(.headline) }
                                ForEach(OperationKind.allCases, id: \.self) { kind in
                                    let count = operations.filter { $0.kind == kind }.count
                                    if count > 0 {
                                        HStack {
                                            Label(kind.label, systemImage: kind.symbol)
                                            Spacer()
                                            Text("\(count)").monospacedDigit().fontWeight(.semibold)
                                        }.font(.callout).foregroundStyle(kind.isDestructive ? SyncStyle.coral : .primary)
                                    }
                                }
                            }
                        }
                    }
                    if !destructive.isEmpty {
                        Divider()
                        Text("\(destructive.filter { $0.kind.isRemoval }.count) bajas · \(destructive.filter { !$0.kind.isRemoval }.count) reemplazos")
                            .font(.headline).foregroundStyle(SyncStyle.coral)
                        ForEach(destructive) { operation in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(operation.title).font(.callout.weight(.medium))
                                Text("\(operation.service.name) · \(operation.kind.destructiveExplanation ?? operation.kind.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(26)
            }.frame(maxHeight: 280)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if !selectionIsCurrent {
                    Notice(title: "La vista previa cambió", message: "Volvé a revisar y seleccionar los cambios antes de confirmar.", symbol: "arrow.clockwise", color: SyncStyle.coral)
                }
                if !destructive.isEmpty {
                    Toggle("Entiendo que estas bajas y reemplazos pueden quitar contenido de la biblioteca o de las playlists de destino.", isOn: $acceptsDestructive)
                        .toggleStyle(.checkbox).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Volver a revisar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(request.isDemo ? "Ejecutar simulación" : "Aplicar \(request.operations.count) cambios") {
                        guard selectionIsCurrent, model.canExecute, destructive.isEmpty || acceptsDestructive else { return }
                        dismiss()
                        model.executeApproved()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(destructive.isEmpty ? SyncStyle.green : SyncStyle.coral)
                    .disabled(!selectionIsCurrent || !model.canExecute || !destructive.isEmpty && !acceptsDestructive)
                }
            }.padding(26)
        }
        .frame(width: 610, height: 620)
    }
}
