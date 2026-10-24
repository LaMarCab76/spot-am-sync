import SwiftUI
import SyncCore

struct NewSyncView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var step = 1
    @ViewState private var name = ""
    @ViewState private var mode: SyncMode = .spotifyBase
    @ViewState private var sourceService: MusicService = .spotify
    @ViewState private var selection = Set<PlaylistReference>()
    @ViewState private var options = SyncOptions()
    @ViewState private var schedule = ReviewSchedule()
    @ViewState private var query = ""
    @ViewState private var targets: [String: String] = [:]
    private var source: MusicService { mode.base ?? sourceService }
    private var playlists: [Playlist] { model.snapshots.first { $0.account.service == source }?.playlists ?? [] }
    private var visible: [Playlist] { playlists.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    private var uniqueTargets: Bool {
        guard options.existingPlaylist == .update else { return true }
        let selected = selection.compactMap { ref -> String? in
            guard let target = targets[ref.id], !target.isEmpty else { return nil }
            return "\(ref.service.other.rawValue):\(target)"
        }
        return Set(selected).count == selected.count
    }
    private var valid: Bool { !selection.isEmpty && uniqueTargets && (!schedule.enabled || schedule.next(after: Date()) != nil) && !model.isBusy && model.workspace.loaded }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PageHeading(eyebrow: model.editingProfileID == nil ? "NUEVA SINCRONIZACIÓN" : "EDITAR CONFIGURACIÓN", title: ["¿Desde dónde y hacia dónde?", "Elegí las playlists.", "Dejalo a tu manera."][step - 1], subtitle: "Paso \(step) de 3 · Primero prepararemos una propuesta para revisar.")
                    HStack(spacing: 16) {
                        ForEach(1...3, id: \.self) { index in
                            HStack(spacing: 8) {
                                Text("\(index)").font(.caption.weight(.semibold)).frame(width: 26, height: 26)
                                    .background(index == step ? SyncStyle.green : Color.white.opacity(0.06), in: Circle())
                                    .foregroundStyle(index == step ? Color.black : Color.secondary)
                                Text(["Dirección", "Playlists", "Opciones"][index - 1]).font(.caption).foregroundStyle(index == step ? .primary : .secondary)
                                if index < 3 { Rectangle().fill(SyncStyle.border).frame(height: 1) }
                            }
                        }
                    }.padding(.bottom, 6)
                    if model.accounts.count < 2 {
                        Notice(title: "Conectá ambos servicios", message: "La sincronización oficial necesita Spotify y Apple Music. También podés usar la lista manual de Apple Music con Spotify y una exportación XML.", symbol: "link")
                        HStack {
                            Button("Conectar cuentas") { model.navigationRequest = .connections }
                            Button("Abrir lista manual") { model.navigationRequest = .manual }
                            Button("Probar demostración") { model.loadDemo() }
                        }
                    } else {
                        switch step {
                        case 1: directionStep
                        case 2: playlistStep
                        default: optionsStep
                        }
                    }
                }.padding(32).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
            }
            HStack(spacing: 14) {
                if step > 1 { Button("Atrás") { step -= 1 } }
                Text(step == 2 ? "\(selection.count) playlists seleccionadas" : "Los cambios necesitan tu confirmación.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if step < 3 {
                    Button("Continuar") { step += 1 }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.accounts.count < 2 || model.isBusy || step == 2 && selection.isEmpty)
                } else {
                    Button("Guardar y preparar propuesta") { submit() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!valid)
                }
            }.padding(.horizontal, 32).padding(.vertical, 18).background(.ultraThinMaterial)
        }
        .onAppear { loadDraft() }
        .onChange(of: mode) { _, value in
            if let base = value.base { selection = selection.filter { $0.service == base } }
            if value == .merge { options.existingPlaylist = .update }
        }
    }
    private var directionStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            TextField("Nombre de esta sincronización", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
            ForEach(SyncMode.allCases) { value in
                Button { mode = value } label: {
                    HStack(spacing: 18) {
                        Image(systemName: mode == value ? "largecircle.fill.circle" : "circle").font(.title3)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(value.title).font(.headline)
                            Text(value == .merge ? "Agregá faltantes en ambos lados. Conservá lo que ya existe." : "La biblioteca base define la propuesta para las playlists seleccionadas en el otro servicio.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            ServiceMark(service: value.base ?? .spotify, size: 34)
                            Image(systemName: value == .merge ? "arrow.left.arrow.right" : "arrow.right")
                            ServiceMark(service: (value.base ?? .spotify).other, size: 34)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                        .background(mode == value ? Color.white.opacity(0.08) : SyncStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(mode == value ? Color.white.opacity(0.4) : SyncStyle.border))
                }.buttonStyle(.plain).accessibilityAddTraits(mode == value ? .isSelected : [])
            }
            Notice(title: "Cada servicio tiene sus capacidades", message: "Las bajas, los reemplazos y los cambios de orden que Apple Music no admite quedarán bloqueados en la propuesta.", symbol: "info.circle")
        }
    }
    private var playlistStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                if mode == .merge {
                    Picker("Elegir desde", selection: $sourceService) { ForEach(MusicService.allCases) { Text($0.name).tag($0) } }.frame(width: 260)
                }
                SearchField(text: $query, prompt: "Buscar playlist")
                Button("Actualizar bibliotecas") { model.refreshLibraries() }.disabled(!model.canAnalyze)
            }
            if playlists.isEmpty {
                EmptyState(symbol: "music.note.list", title: "Cargá las playlists para elegir", message: "Actualizar bibliotecas solo lee los servicios. No aplica cambios.")
            }
            ForEach(visible) { playlist in
                let ref = PlaylistReference(service: source, playlistID: playlist.id)
                HStack(spacing: 14) {
                    Toggle("Seleccionar \(playlist.name)", isOn: Binding(get: { selection.contains(ref) }, set: { value in
                        if value { selection.insert(ref) } else { selection.remove(ref) }
                    })).labelsHidden().toggleStyle(.checkbox)
                    ArtworkView(url: playlist.artworkURL, title: playlist.name, service: source).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(playlist.name).font(.callout.weight(.semibold))
                        Text("\(playlist.tracks.count) canciones\(playlist.contentsComplete ? "" : " · Lectura parcial")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.contains(ref) && options.existingPlaylist == .update {
                        Picker("Vincular con", selection: Binding(get: { targets[ref.id] ?? "" }, set: { targets[ref.id] = $0 })) {
                            Text("Vínculo actual / revisar luego").tag("")
                            ForEach(model.snapshots.first { $0.account.service == source.other }?.playlists ?? []) { target in Text(target.name).tag(target.id) }
                        }.frame(maxWidth: 270)
                    }
                }.padding(13).background(selection.contains(ref) ? Color.white.opacity(0.07) : SyncStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Este alcance solo incluye las playlists elegidas. Las canciones y álbumes guardados se revisan por separado en Bibliotecas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var optionsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !uniqueTargets {
                Notice(title: "Revisá los vínculos de destino", message: "Dos playlists no pueden actualizar el mismo destino en una configuración. Volvé al paso anterior y elegí destinos distintos.", symbol: "link", color: SyncStyle.coral)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Cuando exista en destino").font(.headline)
                    Picker("Playlist de destino", selection: $options.existingPlaylist) {
                        ForEach(ExistingPlaylistPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.disabled(mode == .merge)
                    Text(options.existingPlaylist == .copy ? "La primera ejecución crea una copia. Su ID verificado se conserva para actualizarla después sin volver a crearla." : "Los nombres por sí solos no vinculan playlists. Podés confirmar sus vínculos en Playlists.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Mantener el orden de origen", isOn: $options.keepOrder).disabled(mode == .merge)
                    Text(mode == .merge ? "La fusión conserva el orden existente y agrega las ocurrencias faltantes al final." : "Si lo desactivás, se conserva el orden de los elementos existentes que sigan en la propuesta.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Omitir repeticiones de una misma canción", isOn: $options.skipDuplicates)
                    Text("Desactivado conserva las repeticiones intencionales. Nunca vuelve a enviar un lote ya verificado.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SurfaceCard { ScheduleEditor(schedule: $schedule) }
            Notice(title: "Propuesta antes de aplicar", message: "\(selection.count) playlists · \(mode.title). Las coincidencias ambiguas y las ediciones diferentes necesitan tu elección. Guardar no autoriza escrituras.", symbol: "hand.raised")
        }
    }
    private func loadDraft() {
        if let id = model.editingProfileID, let profile = model.workspace.state.profiles.first(where: { $0.id == id }) {
            name = profile.request.name; mode = profile.request.mode; selection = Set(profile.request.playlists)
            sourceService = profile.request.playlists.first?.service ?? .spotify
            options = profile.request.options; schedule = profile.schedule
            if profile.request.matches(accounts: Array(model.accounts.values)) {
                targets = Dictionary((profile.request.playlistTargets ?? []).map { ($0.source.id, $0.targetID) }, uniquingKeysWith: { first, _ in first })
            } else {
                selection = []; targets = [:]; schedule.enabled = false
            }
        } else { mode = model.workspace.state.preferences.defaultMode; options = model.workspace.state.preferences.options }
    }
    private func submit() {
        if options.existingPlaylist == .update {
            for ref in selection {
                if let target = targets[ref.id], !target.isEmpty {
                    model.linkPlaylists(spotifyID: ref.service == .spotify ? ref.playlistID : target, appleMusicID: ref.service == .appleMusic ? ref.playlistID : target)
                }
            }
        }
        model.createSync(name: name, mode: mode, playlists: Array(selection), options: options, schedule: schedule)
    }
}

struct ScheduleEditor: View {
    @Binding var schedule: ReviewSchedule
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Preparar revisiones programadas", isOn: $schedule.enabled).font(.headline)
            Text("Lee las bibliotecas y avisa cuando hay una propuesta. Siempre pedirá confirmación antes de aplicar cambios.")
                .font(.callout).foregroundStyle(.secondary)
            if schedule.enabled {
                HStack {
                    Picker("Frecuencia", selection: $schedule.frequency) { ForEach(ReviewFrequency.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if schedule.frequency != .hourly {
                        Picker("Hora", selection: $schedule.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 120)
                    }
                    Picker("Minuto", selection: $schedule.minute) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 125)
                }
                if schedule.frequency == .weekly {
                    Picker("Día", selection: $schedule.weekday) {
                        ForEach(Array(["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"].enumerated()), id: \.offset) { index, day in Text(day).tag(index + 1) }
                    }
                }
                TextField("Zona horaria", text: $schedule.timeZoneID).textFieldStyle(.roundedBorder)
                if schedule.next(after: Date()) == nil { Text("Revisá el horario y la zona horaria.").font(.caption).foregroundStyle(SyncStyle.coral) }
            }
            Text("Funciona mientras la app esté ejecutándose, aunque cierres su ventana. Si salís de la app o el Mac duerme, comprueba los horarios vencidos al volver a abrir o despertar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
