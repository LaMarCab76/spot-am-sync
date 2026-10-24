import SwiftUI
import SyncCore

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var removingProfile: UUID?
    private var jobs: [ReviewJob] { model.workspace.state.jobs.sorted { $0.createdAt < $1.createdAt } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeading(eyebrow: "A TU RITMO", title: "Cola y programación", subtitle: "Una propuesta por vez. Cada escritura necesita tu confirmación.")
                    Button("Nueva sincronización", systemImage: "plus") { model.editingProfileID = nil; model.navigationRequest = .newSync }
                        .buttonStyle(.borderedProminent).disabled(model.isBusy).padding(.top, 24)
                }
                if !model.workspace.loaded { ProgressView("Cargando configuraciones…") }
                if jobs.isEmpty {
                    EmptyState(symbol: "calendar.badge.clock", title: "Prepará tu primera propuesta", message: "Elegí las playlists en Nueva sincronización. Podés guardar el alcance y programar sus próximas revisiones.")
                } else {
                    ForEach(jobs) { job in
                        SurfaceCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(job.request.name).font(.headline)
                                        Text("\(job.request.mode.title) · \(job.request.playlists.count) playlists · \(job.scheduled ? "Revisión programada" : "A pedido")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    StatusPill(title: job.state.title, symbol: job.state == .ready ? "hand.raised" : "clock", color: job.state == .attention ? SyncStyle.coral : SyncStyle.green)
                                }
                                Text(job.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if !job.request.matches(accounts: Array(model.accounts.values)) {
                                    Label("Conectá las cuentas y región de esta configuración.", systemImage: "link").font(.caption).foregroundStyle(SyncStyle.coral)
                                }
                                HStack {
                                    Text(job.createdAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    if job.state == .ready || job.state == .completed && job.plan != nil {
                                        Button(job.state == .ready ? "Revisar propuesta" : "Ver análisis") { model.openJob(job) }.buttonStyle(.borderedProminent)
                                    }
                                    if [.paused, .attention, .completed].contains(job.state) {
                                        Button("Preparar de nuevo") { model.workspace.prepareAgain(job.id) }
                                    }
                                    if [.queued, .analyzing, .applying].contains(job.state) {
                                        Button(job.state == .applying ? "Detener nuevas operaciones" : "Pausar") { model.pauseJob(job) }
                                            .disabled(model.isBusy && model.activeJobID != job.id)
                                    }
                                    if job.state != .applying && job.state != .analyzing {
                                        Button("Quitar de la cola") { model.workspace.removeJob(job.id) }
                                    }
                                }.disabled(model.isBusy && model.activeJobID != job.id)
                            }
                        }
                    }
                }
                Divider().padding(.vertical, 6)
                Text("Configuraciones guardadas").font(.title2.weight(.semibold))
                if model.workspace.state.profiles.isEmpty {
                    Text("Al crear una sincronización se guarda su alcance, dirección y opciones.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.workspace.state.profiles) { profile in
                    SurfaceCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(profile.request.name).font(.headline)
                                Spacer()
                                Toggle("Programada", isOn: Binding(get: { profile.schedule.enabled }, set: { enabled in model.changeProfile(profile.id) { $0.schedule.enabled = enabled } }))
                                    .toggleStyle(.switch).fixedSize().disabled(model.isBusy)
                            }
                            Text("\(profile.request.playlists.count) playlists · \(profile.request.mode.title) · Revisión \(profile.request.revision)").font(.caption).foregroundStyle(.secondary)
                            if profile.schedule.enabled {
                                Text("\(profile.schedule.frequency.title) · \(profile.schedule.timeZoneID)").font(.caption)
                                if let next = profile.schedule.nextReview {
                                    HStack {
                                        Text("Próxima revisión:")
                                        Text(next, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                                    }.font(.caption).foregroundStyle(.secondary)
                                        .environment(\.timeZone, TimeZone(identifier: profile.schedule.timeZoneID) ?? .current)
                                }
                            }
                            HStack {
                                Button("Preparar ahora") { _ = model.workspace.enqueue(profile.request); model.workspaceTick() }
                                    .disabled(model.isBusy || !profile.request.matches(accounts: Array(model.accounts.values)))
                                Button("Editar") { model.editingProfileID = profile.id; model.navigationRequest = .newSync }.disabled(model.isBusy)
                                Spacer()
                                Button("Eliminar configuración", role: .destructive) { removingProfile = profile.id }.disabled(model.isBusy)
                            }
                        }
                    }
                }
                Notice(title: "Programar no autoriza cambios", message: "La app analiza mientras está ejecutándose y comprueba revisiones vencidas al iniciar o despertar. Las propuestas quedan acá aunque las notificaciones de macOS estén desactivadas.", symbol: "hand.raised")
            }.padding(32)
        }
        .confirmationDialog("¿Eliminar esta configuración? Las playlists y el historial se conservan.", isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } })) {
            Button("Eliminar configuración", role: .destructive) {
                if let id = removingProfile { model.workspace.removeProfile(id: id) }
                removingProfile = nil
            }
        }
    }
}
