import SwiftUI
import SyncCore

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var stopping = false
    private var syncing: Bool { if case .syncing = model.phase { return true }; return false }
    private var fraction: Double { model.progress.isFinite ? min(max(model.progress, 0), 1) : 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: model.isDemo ? "Ejecución de ejemplo" : "Paso a paso", title: model.isReconciling ? "Comprobando la ejecución anterior" : syncing ? "Tu música se está sincronizando" : "Actividad y resultado", subtitle: model.isReconciling ? "Esta comprobación sólo lee las bibliotecas. Para continuar tendrás que revisar y confirmar un nuevo plan." : syncing ? "Podés seguir el avance y detener nuevas operaciones cuando lo necesites." : "Revisá qué se verificó, qué quedó pendiente y el detalle de la ejecución.")
                if syncing {
                    SurfaceCard {
                        HStack(spacing: 24) {
                            ZStack {
                                Circle().stroke(SyncStyle.green.opacity(0.12), lineWidth: 7)
                                Circle().trim(from: 0, to: fraction).stroke(SyncStyle.green, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            }.frame(width: 100, height: 100).padding(6)
                                .accessibilityElement(children: .ignore).accessibilityLabel("Progreso").accessibilityValue("\(Int(fraction * 100)) por ciento")
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.isReconciling ? "Verificando el resultado pendiente" : model.isDemo ? "Simulación en curso" : "Aplicando y verificando cambios").font(.title3.weight(.semibold))
                                Text(model.statusText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("\(model.completedCount) de \(model.totalCount) operaciones verificadas")
                                    .font(.caption).foregroundStyle(SyncStyle.green).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                            Button(stopping ? "Deteniendo…" : "Cancelar") {
                                stopping = true; model.cancel()
                            }.disabled(stopping)
                        }
                    }
                    Notice(title: "Cancelar detiene las operaciones siguientes", message: "La app comprueba la operación que ya esté en curso. Los cambios verificados hasta ese momento se conservan.", symbol: "pause.circle")
                } else if let result = model.lastResult {
                    RunResultCard(summary: result, isDemo: model.isDemo)
                    exportActions
                } else if !model.logs.isEmpty {
                    Notice(title: "Revisá el detalle de la actividad", message: model.statusText, symbol: "info.circle", color: SyncStyle.coral)
                } else {
                    EmptyState(symbol: "waveform.path", title: "Todo listo para seguir el avance", message: "Después de seleccionar y confirmar cambios, vas a ver acá el progreso y su resultado.")
                }
                if model.canResume && !model.isBusy {
                    SurfaceCard {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("Hay una ejecución pendiente", systemImage: "arrow.clockwise.circle").font(.headline)
                                Text("Comprobá qué cambios llegaron al servicio. Para aplicar lo que falta, volvé a analizar y confirmar la vista previa.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Comprobar pendientes") { model.resume() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if syncing || !model.logs.isEmpty {
                    LogView(logs: model.logs, title: "Detalle de la actividad", followsUpdates: syncing)
                }
            }.padding(28)
        }
        .onReceive(model.$phase) { phase in if case .syncing = phase {} else { stopping = false } }
    }

    private var exportActions: some View {
        HStack(spacing: 10) {
            Button { model.exportReport() } label: { Label("Exportar informe", systemImage: "square.and.arrow.up") }
            Button { model.exportBackup() } label: { Label("Exportar respaldo", systemImage: "externaldrive") }
            Spacer()
        }.disabled(model.isBusy)
    }
}

struct RunResultCard: View {
    let summary: RunSummary
    var isDemo = false
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: summary.status.displaySymbol).font(.system(size: 28)).foregroundStyle(summary.status.displayColor)
                        .frame(width: 48, height: 48).background(summary.status.displayColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary.status.displayTitle).font(.title2.weight(.semibold))
                        Text(summary.startedAt, format: .dateTime.day().month(.wide).year().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isDemo || summary.isDemoSummary { StatusPill(title: "Demostración", symbol: "flask", color: SyncStyle.coral) }
                }
                if !summary.message.isEmpty { Text(summary.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack(spacing: 30) {
                    resultMetric("Verificadas", count: summary.verifiedCount, color: SyncStyle.green)
                    resultMetric("Operaciones del plan aprobado", count: summary.totalCount, color: .primary)
                    resultMetric("Sin verificar", count: max(0, summary.totalCount - summary.verifiedCount), color: summary.totalCount > summary.verifiedCount ? SyncStyle.coral : .secondary)
                    Spacer(minLength: 0)
                }
                if summary.status != .completed {
                    Text("Revisá los mensajes antes de volver a ejecutar. Un resultado parcial o interrumpido no confirma que las bibliotecas hayan quedado iguales.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func resultMetric(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(count)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct LogView: View {
    let logs: [String]
    let title: String
    var followsUpdates = false
    @ViewState private var autoScroll = true
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(title, systemImage: "text.alignleft").font(.headline)
                    Spacer()
                    if followsUpdates { Toggle("Seguir el avance", isOn: $autoScroll).toggleStyle(.checkbox).font(.caption) }
                    Text("\(logs.count) mensajes").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if logs.isEmpty {
                                Text("Los mensajes van a aparecer a medida que avance la ejecución.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
                            }
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 25, alignment: .trailing)
                                    Text(line).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                }.padding(.vertical, 7).id(index)
                            }
                        }
                    }.frame(minHeight: 150, maxHeight: 310)
                        .onChange(of: logs.count) { _, _ in
                            if followsUpdates && autoScroll, let index = logs.indices.last { proxy.scrollTo(index, anchor: .bottom) }
                        }
                }
            }
        }
    }
}

extension RunStatus {
    var displayTitle: String {
        switch self {
        case .completed: return "Sincronización completada"
        case .partial: return "Con diferencias pendientes"
        case .cancelled: return "Ejecución cancelada"
        case .failed: return "La ejecución necesita revisión"
        case .running: return "Sincronización en curso"
        case .interrupted: return "Ejecución interrumpida"
        }
    }
    var displaySymbol: String {
        switch self {
        case .completed: return "checkmark.circle"
        case .partial: return "circle.lefthalf.filled"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        case .running: return "arrow.triangle.2.circlepath"
        case .interrupted: return "pause.circle"
        }
    }
    var displayColor: Color {
        switch self {
        case .completed, .running: return SyncStyle.green
        case .partial, .failed, .interrupted: return SyncStyle.coral
        case .cancelled: return .secondary
        }
    }
}

extension RunSummary {
    // AppModel.refreshHistory marks demo records in the public summary message.
    var isDemoSummary: Bool { message.hasPrefix("Demostración:") }
}
