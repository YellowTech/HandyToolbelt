import AppKit
import SwiftUI

struct PowerSettingsView: View {
    @ObservedObject var model: PowerModel
    @State private var showPowerHelp = false
    @State private var showHealthHelp = false
    @State private var settingsError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Power").font(.system(size: 27, weight: .semibold))
                    Text("Check battery health, charging, and live power use.").font(.callout).foregroundStyle(Theme.secondary)
                }
                if model.reading.batteryPresent == false {
                    ContentUnavailableView("No built-in battery", systemImage: "battery.0percent", description: Text("Power monitors the battery in a Mac notebook."))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(source).font(.headline)
                            Text(model.flowState.status).foregroundStyle(Theme.secondary)
                            Spacer()
                            Button { showPowerHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                                .buttonStyle(.plain).accessibilityLabel("About power flow")
                                .popover(isPresented: $showPowerHelp) {
                                    Text("Power readings refresh every two seconds while this window is active. Mac power is estimated from electrical readings; arrows show direction, not exact proportions. Adapter input is current power, while its rating is maximum output. Flow pauses briefly when the source changes.")
                                        .font(.callout).padding(16).frame(width: 310)
                                }
                        }
                        PowerFlowDiagram(reading: model.reading, flow: model.flowState)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Battery details").font(.headline)
                        row("Cycle count", value: model.reading.cycleCount.map(String.init) ?? "Unavailable")
                        row("Full charge capacity", value: capacity(model.reading.fullChargeCapacityMAh))
                        row("Design capacity", value: capacity(model.reading.designCapacityMAh))
                        HStack {
                            Text("Estimated health").foregroundStyle(Theme.secondary)
                            Button { showHealthHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                                .buttonStyle(.plain).accessibilityLabel("About estimated battery health")
                                .popover(isPresented: $showHealthHelp) {
                                    Text(healthHelp)
                                        .font(.callout).padding(16).frame(width: 290)
                                }
                            Spacer()
                            Text(model.reading.estimatedHealthPercent.map { String(format: model.reading.healthEstimateSource == "nominalCapacity" ? "%.0f%%" : "%.1f%%", $0) } ?? "Unavailable").monospacedDigit()
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Charging").font(.headline)
                        Text(chargingHelp).font(.callout).foregroundStyle(Theme.secondary)
                        Button("Open Battery Settings…", action: openBatterySettings)
                        if let settingsError {
                            Text(settingsError).font(.callout).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(Theme.secondary)
                }
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
    }
    private var healthHelp: String {
        let basis = model.reading.healthEstimateSource == "nominalCapacity"
            ? "Estimated from nominal long-term capacity compared with design capacity."
            : "Estimated from full charge capacity compared with design capacity; nominal capacity is unavailable."
        return basis + " This may differ from the percentage in macOS Battery Health."
    }
    private var chargingHelp: String {
        #if arch(arm64)
        if #available(macOS 26.4, *) {
            return "In Battery settings, click the info button beside Charging, then use the Charge Limit slider."
        }
        #endif
        return "Manage charging options in macOS Battery settings."
    }
    private func capacity(_ value: Double?) -> String { value.map { String(format: "%.0f mAh", $0) } ?? "Unavailable" }
    private func openBatterySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        settingsError = NSWorkspace.shared.open(url) ? nil : "Open System Settings → Battery to manage charging."
    }
    private var source: String {
        switch model.reading.powerSource { case "ac": return "Power adapter"; case "battery": return "Battery"; default: return "Unavailable" }
    }
    private func row(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.secondary); Spacer(); Text(value).monospacedDigit() }
    }
}

/// Static direction markers keep the live readings legible and require no animation timer.
private struct PowerFlowDiagram: View {
    let reading: PowerReading
    let flow: PowerFlowState
    private var adapterActive: Bool { flow.permitsAdapterFlow && (reading.inputWatts ?? 0) > 0 }
    private var macActive: Bool { (adapterActive || flow.batterySupplies) && (reading.estimatedMacWatts ?? 0) > 0 }
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let left = width * 0.15
            let middle = width * 0.5
            let right = width * 0.85
            ZStack(alignment: .topLeading) {
                connector(from: CGPoint(x: left + 30, y: 30), to: CGPoint(x: middle, y: 30), active: adapterActive)
                connector(from: CGPoint(x: middle, y: 30), to: CGPoint(x: right - 36, y: 30), active: macActive)
                connector(from: CGPoint(x: middle, y: flow.batterySupplies ? 128 : 30),
                          to: CGPoint(x: middle, y: flow.batterySupplies ? 30 : 128),
                          active: flow.batteryCharges || flow.batterySupplies)
                Circle().fill(adapterActive || flow.batterySupplies ? Theme.accent : Theme.separator)
                    .frame(width: 6, height: 6).position(x: middle, y: 30)
                node(symbol: "powerplug", title: reading.externalConnected == false ? "Disconnected" : "Adapter",
                     value: reading.externalConnected == false ? "—" : watts(reading.inputWatts),
                     detail: reading.adapterWatts.map { String(format: "Rated %.0f W", $0) }, muted: reading.externalConnected == false)
                    .position(x: left, y: 61)
                node(symbol: "laptopcomputer", title: "Mac", value: watts(reading.estimatedMacWatts), detail: "Estimated")
                    .position(x: right, y: 61)
                node(symbol: batterySymbol, title: "Battery", value: reading.chargePercent.map { "\($0)%" } ?? "Unavailable",
                     detail: batteryDetail).position(x: middle, y: 177)
            }
        }
        .frame(height: 238)
        .accessibilityElement(children: .combine)
    }
    private var batterySymbol: String {
        let level = reading.chargePercent ?? 0
        return "battery.\(level >= 90 ? 100 : level >= 65 ? 75 : level >= 40 ? 50 : level >= 15 ? 25 : 0)percent"
    }
    private var batteryDetail: String {
        if flow == .settling { return "Updating…" }
        if flow.batteryCharges { return "Charging · \(watts(reading.batteryWatts))" }
        if flow.batterySupplies { return "Supplying · \(watts(reading.batteryWatts.map(abs)))" }
        if flow == .idle || flow == .disconnected { return reading.isCharged == true ? "Fully charged · Idle" : "Idle" }
        return "Flow unavailable"
    }
    private func watts(_ value: Double?) -> String { value.map { String(format: "%.1f W", $0) } ?? "Unavailable" }
    private func node(symbol: String, title: String, value: String, detail: String?, muted: Bool = false) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 31, weight: .regular)).frame(height: 38)
            Text(title).font(.callout).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            Text(detail ?? " ").font(.caption).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .foregroundStyle(muted ? Theme.secondary : Theme.text)
        .frame(width: 190)
    }
    private func connector(from start: CGPoint, to end: CGPoint, active: Bool) -> some View {
        Path { path in
            path.move(to: start); path.addLine(to: end)
            if active {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let tip = CGPoint(x: start.x + (end.x - start.x) * 0.7, y: start.y + (end.y - start.y) * 0.7)
                for offset in [-0.55, 0.55] {
                    path.move(to: tip)
                    path.addLine(to: CGPoint(x: tip.x - cos(angle + offset) * 8, y: tip.y - sin(angle + offset) * 8))
                }
            }
        }
        .stroke(active ? Theme.accent : Theme.separator, style: StrokeStyle(lineWidth: active ? 2 : 1, lineCap: .round, dash: active ? [] : [4, 4]))
        .accessibilityHidden(true)
    }
}
