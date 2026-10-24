import AppKit
import Combine
import SyncCore
import UserNotifications

@MainActor
final class WorkspaceCoordinator: ObservableObject {
    @Published private(set) var state = SyncWorkspace()
    @Published private(set) var loaded = false
    @Published var errorMessage: String?
    @Published private(set) var notificationStatus = "Sin solicitar"
    private var realState = SyncWorkspace()
    private var demoState = SyncWorkspace()
    private var demo = false
    private var store: SyncStore?
    private var saveTask: Task<Void, Error>?
    private var timer: AnyCancellable?
    private var wake: AnyCancellable?
    private var tickAction: (() -> Void)?
    private var systemServices = true

    func start(store: SyncStore, systemServices: Bool = true, tick: @escaping () -> Void) {
        self.store = store; tickAction = tick
        self.systemServices = systemServices
        Task {
            do {
                let restored = try await store.loadWorkspace()
                realState = try await store.restoreVerifiedTargets(in: restored); realState.recoverAfterRestart()
                if !demo { state = realState }
                loaded = true; persist(); tick()
            } catch { errorMessage = error.localizedDescription }
        }
        if systemServices {
            timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { _ in tick() }
            wake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { _ in tick() }
        }
    }

    func switchDemo(_ value: Bool) {
        guard demo != value else { return }
        if demo { demoState = state } else { realState = state }
        demo = value; state = value ? demoState : realState
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        update(&state.preferences); persist()
    }

    @discardableResult
    func addProfile(request: SyncRequest, schedule: ReviewSchedule) -> SyncProfile {
        var profile = SyncProfile(request: request, schedule: schedule, isDemo: demo)
        if profile.schedule.enabled { profile.schedule.nextReview = profile.schedule.next(after: Date()) }
        state.profiles.append(profile); persist(); return profile
    }

    func updateProfile(id: UUID, update: (inout SyncProfile) -> Void) {
        guard let i = state.profiles.firstIndex(where: { $0.id == id }),
              !state.jobs.contains(where: { $0.request.profileID == id && $0.state == .applying }) else { return }
        update(&state.profiles[i]); state.profiles[i].request.revision += 1
        state.profiles[i].schedule.nextReview = state.profiles[i].schedule.next(after: Date())
        for j in state.jobs.indices where state.jobs[j].request.profileID == id && state.jobs[j].state.pending {
            state.jobs[j].state = .attention; state.jobs[j].plan = nil
            state.jobs[j].message = "La configuración cambió. Prepará una propuesta nueva."
        }
        persist()
    }

    func removeProfile(id: UUID) {
        guard !state.jobs.contains(where: { $0.request.profileID == id && $0.state == .applying }) else { return }
        state.profiles.removeAll { $0.id == id }
        for i in state.jobs.indices where state.jobs[i].request.profileID == id && state.jobs[i].state.pending {
            state.jobs[i].state = .attention; state.jobs[i].plan = nil; state.jobs[i].message = "La configuración fue eliminada."
        }
        persist()
    }

    @discardableResult
    func enqueue(_ request: SyncRequest, scheduled: Bool = false) -> UUID? {
        guard loaded else { return nil }
        if let old = state.jobs.first(where: { $0.request == request && $0.state.pending }) { return old.id }
        let job = ReviewJob(request: request, scheduled: scheduled, isDemo: demo)
        state.jobs.append(job); persist(); return job.id
    }

    func scheduleTick(accounts: [ConnectedAccount], now: Date = Date()) {
        guard loaded, !demo else { return }
        let before = state
        state.enqueueDue(at: now, accounts: accounts)
        if before != state { persist() }
    }

    func setJob(_ id: UUID, state newState: ReviewJobState, message: String? = nil) {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { return }
        state.jobs[i].state = newState
        if let message { state.jobs[i].message = message }
        persist()
    }

    func ready(_ id: UUID, plan: SyncPlan, decisions: MatchDecisions) {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }) else { return }
        let announce = state.jobs[i].state != .ready
        let noChanges = plan.operations.isEmpty && plan.issues.isEmpty
        state.jobs[i].state = noChanges ? .completed : .ready; state.jobs[i].plan = plan; state.jobs[i].decisions = decisions
        state.jobs[i].message = noChanges ? "Revisión completa: no hay cambios propuestos en este alcance." : "\(plan.executable.count) operaciones disponibles · \(plan.issues.count) observaciones. Esperando tu revisión."
        if let profileID = plan.request?.profileID, let p = state.profiles.firstIndex(where: { $0.id == profileID }) {
            state.profiles[p].schedule.lastReview = Date()
        }
        persist()
        if announce && !noChanges && state.jobs[i].scheduled && state.preferences.notifyReview { notify(title: "Cambios para revisar", body: plan.request?.name ?? "Tu propuesta está lista.") }
    }

    func prepareAgain(_ id: UUID) {
        guard let i = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[i].state != .applying else { return }
        if let profileID = state.jobs[i].request.profileID {
            guard let profile = state.profiles.first(where: { $0.id == profileID }) else {
                setJob(id, state: .attention, message: "La configuración ya no existe."); return
            }
            state.jobs[i].request = profile.request
        }
        state.jobs[i].plan = nil; state.jobs[i].decisions = nil; state.jobs[i].state = .queued
        persist(); tickAction?()
    }

    func removeJob(_ id: UUID) {
        guard state.jobs.first(where: { $0.id == id })?.state != .applying else { return }
        state.jobs.removeAll { $0.id == id }; persist()
    }

    func validate(_ request: SyncRequest?) -> Bool {
        guard let request, let profileID = request.profileID else { return true }
        return state.profiles.contains { $0.id == profileID && $0.request == request }
    }

    func invalidateDrafts(accountIDs: [MusicService: String], except jobID: UUID?) {
        var changed = false
        for i in state.jobs.indices where state.jobs[i].id != jobID && [.ready, .paused].contains(state.jobs[i].state) {
            guard state.jobs[i].request.accountIDs.contains(where: { accountIDs[$0.key] == $0.value }) else { continue }
            state.jobs[i].state = .attention; state.jobs[i].plan = nil
            state.jobs[i].message = "Las correspondencias o protecciones cambiaron. Prepará una propuesta nueva."
            changed = true
        }
        if changed { persist() }
    }

    func beginApplying(jobID: UUID?, request: SyncRequest?) async throws {
        guard validate(request) else { throw SyncExecutionError.stale("La configuración fue modificada.") }
        if let jobID, state.jobs.first(where: { $0.id == jobID })?.state != .ready { throw SyncExecutionError.invalidSelection }
        if let jobID { setJob(jobID, state: .applying, message: "Aplicando los cambios que confirmaste.") }
        try await saveTask?.value
    }

    func finish(_ record: RunRecord, jobID: UUID?) {
        let targets = record.executions.filter { $0.state == .verified && $0.operation.kind == .createPlaylist }.compactMap { step -> PlaylistTarget? in
            guard let ref = step.operation.sourcePlaylist, let id = step.receipt?.createdID else { return nil }
            return PlaylistTarget(source: ref, targetID: id)
        }
        if let profileID = record.plan.request?.profileID,
           let p = state.profiles.firstIndex(where: { $0.id == profileID }), state.profiles[p].request.revision == record.plan.request?.revision {
            for target in targets {
                if record.plan.request?.options.existingPlaylist == .copy {
                    state.profiles[p].request.copyTargets.removeAll { $0.source == target.source }
                    state.profiles[p].request.copyTargets.append(target)
                } else {
                    state.profiles[p].request.playlistTargets = (state.profiles[p].request.playlistTargets ?? []).filter { $0.source != target.source } + [target]
                }
            }
        }
        if let jobID, let i = state.jobs.firstIndex(where: { $0.id == jobID }) {
            state.jobs[i].state = record.summary.status == .completed ? .completed : .attention
            state.jobs[i].runID = record.id; state.jobs[i].plan = nil; state.jobs[i].message = record.summary.message
        }
        persist()
        if record.summary.status == .completed && state.preferences.notifyDone { notify(title: "Sincronización verificada", body: record.summary.message) }
        else if record.summary.status != .completed && state.preferences.notifyFailure { notify(title: "Revisá la sincronización", body: record.summary.message) }
    }

    func clearConfigurations() { state = SyncWorkspace(); persist() }

    func flush() async throws { try await saveTask?.value }

    func recoverVerifiedTargets() async throws {
        guard !demo, let store else { return }
        let recovered = try await store.restoreVerifiedTargets(in: state)
        if recovered != state { state = recovered; persist(); try await flush() }
    }

    private func persist() {
        guard loaded, !demo, let store else { return }
        realState = state
        let value = state, previous = saveTask
        saveTask = Task {
            _ = try? await previous?.value
            do { try await store.saveWorkspace(value) }
            catch { errorMessage = error.localizedDescription; throw error }
        }
    }

    func requestNotifications() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationStatus = granted ? "Permitidas" : "Desactivadas en macOS"
            } catch { notificationStatus = error.localizedDescription }
        }
    }

    func notify(title: String, body: String) {
        guard !demo, systemServices else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent(); content.title = title; content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
