import SwiftUI

/// The Battery page: this Mac, any iPhone/iPad on a cable, and the health history.
struct BatteryView: View {
    @ObservedObject var model = BatteryModel.shared
    @State private var selection: String?
    private let historyID = "history"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.allPresentations) { p in chip(p) }
                    if model.devices.isEmpty {
                        Label(model.iosSupported ? "Connect an iPhone or iPad with a cable" : "iOS devices unavailable",
                              systemImage: "cable.connector")
                            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    Spacer(minLength: 12)
                    Button { selection = historyID } label: {
                        Label("History", systemImage: "chart.xyaxis.line").padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(selection == historyID ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 9))
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environmentObject(model)
        .environmentObject(model.history)
        .onAppear {
            model.start()
            if selection == nil { selection = model.macID }
        }
    }

    func chip(_ p: DevicePresentation) -> some View {
        Button { selection = p.id } label: {
            HStack(spacing: 8) {
                Image(systemName: p.symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.title).lineLimit(1)
                    if let b = p.battery {
                        MiniBar(fraction: Double(b.percent) / 100, color: chargeColor(b)).frame(width: 90)
                    } else {
                        Text(p.kind == "mac" ? "no battery" : "action needed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let b = p.battery {
                    Text(verbatim: "\(b.percent)%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .background(selection == p.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder var detail: some View {
        if selection == historyID {
            HistoryView()
        } else if let p = model.allPresentations.first(where: { $0.id == selection }) {
            DeviceDetailView(device: p)
        } else {
            ContentUnavailableView("Device disconnected", systemImage: "cable.connector.slash",
                                   description: Text("Connect it again with a cable and unlock it."))
        }
    }
}
