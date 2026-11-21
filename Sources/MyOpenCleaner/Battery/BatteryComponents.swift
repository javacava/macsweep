import SwiftUI

func chargeColor(_ b: BatteryInfo) -> Color {
    if b.percent <= 10 { return .red }
    if b.percent <= 20 { return .orange }
    return .green
}

func healthColor(_ health: Double) -> Color {
    if health >= 80 { return .green }
    if health >= 60 { return .orange }
    return .red
}

func batterySymbol(percent: Int, charging: Bool) -> String {
    if charging { return "battery.100percent.bolt" }
    switch percent {
    case 88...: return "battery.100percent"
    case 63...: return "battery.75percent"
    case 38...: return "battery.50percent"
    case 13...: return "battery.25percent"
    default: return "battery.0percent"
    }
}

func localizedCondition(_ c: String) -> String {
    switch c.lowercased() {
    case "good", "normal": return "Normal"
    case "fair": return "Fair"
    case "poor": return "Poor"
    case "check battery", "service battery", "service recommended", "permanent battery failure":
        return "Service recommended"
    default: return c
    }
}

struct CapacityBar: View {
    let title: String
    let valueText: String
    let fraction: Double
    let color: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(valueText).font(.title3.weight(.medium).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.gradient)
                        .frame(width: max(10, geo.size.width * min(1, max(0, fraction))))
                    Text(label)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 26)
            .animation(.easeOut(duration: 0.3), value: fraction)
        }
    }
}

struct StatTile: View {
    let symbol: String
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}
