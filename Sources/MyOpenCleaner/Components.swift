import SwiftUI
import SweepCore

/// Page frame used by every module: header with icon, title, subtitle and actions, then content.
struct ModulePage<Content: View, Actions: View>: View {
    let module: Module
    var subtitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: module.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(module.tint.gradient, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title).font(.title2.bold())
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                actions
            }
            .padding(20)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Centered placeholder for "not scanned yet", "scanning" and "all clean" states.
struct StateView: View {
    var symbol: String
    var title: String
    var message: String = ""
    var busy = false
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if busy {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: symbol).font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            }
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let buttonTitle, let action {
                Button(buttonTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SizeText: View {
    let bytes: Int64
    var body: some View {
        Text(FileSize.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
    }
}

/// A checkbox row with a path, size and a Reveal-in-Finder button.
struct FileRow: View {
    @Binding var isOn: Bool
    let url: URL
    var title: String? = nil
    var detail: String? = nil
    let size: Int64

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            FileIcon(url: url).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(detail ?? AppState.shared.display(url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SizeText(bytes: size)
            Button { AppState.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 2)
    }
}

/// The Finder icon of a file. In demo mode a neutral symbol instead, because Finder icons reveal
/// which apps are installed on the Mac that renders the screenshot.
struct FileIcon: View {
    let url: URL

    var body: some View {
        if Demo.active == nil || url.pathExtension == "app" {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: Self.symbol(url)).resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
        }
    }

    static func symbol(_ url: URL) -> String {
        if url.isDirectoryURL { return "folder.fill" }
        switch FileKind.of(url) {
        case .video: return "film"
        case .audio: return "waveform"
        case .image: return "photo"
        case .archive: return "doc.zipper"
        case .diskImage: return "opticaldiscdrive"
        case .document: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }
}

/// Bottom bar with selected size and the main destructive button.
struct ActionBar: View {
    let selectedCount: Int
    let selectedSize: Int64
    let buttonTitle: String
    var busy = false
    let action: () -> Void
    @AppStorage(AppState.removalModeKey) private var removalMode = RemovalMode.trash.rawValue

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected: \(selectedCount)").font(.callout)
                Text(removalMode == RemovalMode.trash.rawValue ? "Files will be moved to the Trash" : "Files will be deleted permanently")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(FileSize.format(selectedSize)).font(.title3.monospacedDigit().weight(.semibold))
            Button(action: action) {
                if busy { ProgressView().controlSize(.small).padding(.horizontal, 20) } else { Text(buttonTitle).padding(.horizontal, 8) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedCount == 0 || busy)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
    }
}

/// Summary of a finished clean, shown as an alert message.
func cleanSummary(_ r: CleanReport) -> String {
    var s = "Freed \(FileSize.format(r.freedBytes)), items: \(r.removed.count)."
    if !r.failed.isEmpty {
        s += "\nFailed: \(r.failed.count)"
        if let first = r.failed.first { s += " (\(first.url.lastPathComponent): \(first.reason))" }
    }
    return s
}

struct GaugeRing: View {
    let fraction: Double
    let label: String
    let value: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 9)
                Circle().trim(from: 0, to: max(0.001, min(fraction, 1)))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value).font(.headline.monospacedDigit())
            }
            .frame(width: 92, height: 92)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

extension Set where Element == String {
    mutating func toggle(_ id: String, _ on: Bool) { if on { insert(id) } else { remove(id) } }
}

/// A checkbox binding for one id inside a selection set.
func member(_ set: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
    Binding(get: { set.wrappedValue.contains(id) }, set: { set.wrappedValue.toggle(id, $0) })
}
