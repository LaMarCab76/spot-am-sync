import AppKit
import SwiftUI

@main
struct SpotAMSyncApp: App {
    @NSApplicationDelegateAdaptor(SpotAMSyncAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @ViewState private var didLaunch = false

    var body: some Scene {
        WindowGroup("SpotAM Sync") {
            MainView()
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: "es_AR"))
                .onAppear {
                    guard !didLaunch else { return }
                    didLaunch = true
                    if ProcessInfo.processInfo.arguments.contains("--demo") { model.loadDemo() }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 1150, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Bibliotecas") {
                Button("Analizar bibliotecas") { model.analyze() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canAnalyze || model.isBusy)
                Button("Cargar demostración") { model.loadDemo() }.disabled(model.isBusy)
                Divider()
                Button("Exportar informe") { model.exportReport() }.disabled(model.isBusy || model.plan == nil && model.lastResult == nil)
                Button("Exportar respaldo") { model.exportBackup() }.disabled(model.isBusy || model.snapshots.isEmpty)
            }
        }

        Settings {
            VStack(spacing: 0) {
                if model.isDemo {
                    Notice(title: "Modo demostración", message: "Las cuentas y bibliotecas mostradas son de ejemplo. Conectá tus servicios para trabajar con datos reales.", symbol: "flask", color: SyncStyle.coral).padding(16)
                }
                ConnectionsView()
            }
            .environmentObject(model).environment(\.locale, Locale(identifier: "es_AR")).tint(SyncStyle.green)
            .frame(minWidth: 740, idealWidth: 800, minHeight: 620, idealHeight: 740)
            .alert("No se pudo completar la acción", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("Entendido", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }
}

final class SpotAMSyncAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
