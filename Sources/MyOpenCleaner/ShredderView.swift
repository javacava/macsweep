import SwiftUI
import UniformTypeIdentifiers
import SweepCore

/// Files waiting to be shredded. Shared so files dropped on the Dock icon land here too.
@MainActor
final class ShredderQueue: ObservableObject {
    static let shared = ShredderQueue()
    @Published var items: [URL] = []

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.path))
        items += urls.map(\.standardizedFileURL).filter { !known.contains($0.path) }
    }
}

struct ShredderView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var queue = ShredderQueue.shared
    @AppStorage("shredPasses") private var passes = 1
    @State private var sizes: [String: Int64] = [:]
    @State private var targeted = false
    @State private var busy = false
    @State private var current = ""
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    var total: Int64 { queue.items.reduce(0) { $0 + (sizes[$1.path] ?? 0) } }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = queue.items
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .shredder, subtitle: "Drop files or folders here: their contents are overwritten with random data and deleted, bypassing the Trash.") {
            Picker("Passes", selection: $passes) {
                Text("1 pass").tag(1)
                Text("3 passes").tag(3)
                Text("7 passes").tag(7)
            }
            .frame(width: 150)
            Button("Add…", action: choose)
        } content: {
            VStack(spacing: 0) {
                if queue.items.isEmpty {
                    dropZone
                } else {
                    List {
                        ForEach(queue.items, id: \.path) { url in
                            HStack(spacing: 10) {
                                FileIcon(url: url).frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Text(state.display(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                SizeText(bytes: sizes[url.path] ?? 0)
                                Button { queue.items.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from list")
                            }
                        }
                    }
                    .overlay(targeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.red, lineWidth: 3).padding(4) : nil)
                }
                Label("On an SSD, overwriting does not guarantee the old blocks are physically destroyed. FileVault is the real protection.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                HStack {
                    if busy { Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    else if !queue.items.isEmpty { Button("Clear list") { queue.items = [] } }
                    Spacer()
                    Text(FileSize.format(total)).font(.title3.monospacedDigit().weight(.semibold))
                    Button(action: { askConfirm() }) {
                        if busy { ProgressView().controlSize(.small).padding(.horizontal, 20) }
                        else { Label("Shred", systemImage: "scissors").padding(.horizontal, 6) }
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .disabled(queue.items.isEmpty || busy)
                }
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted, perform: drop)
        }
        .onChange(of: queue.items) { measure() }
        .onAppear(perform: measure)
        .confirmationDialog("Shred \(queue.items.count) items permanently?", isPresented: $confirm) {
            Button("Shred", role: .destructive, action: shred)
        } message: { Text((inUse.map { $0 + "\n\n" } ?? "") + "They will not go to the Trash and cannot be recovered.") }
        .doneAlert($message)
    }

    var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "scissors").font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? .red : .secondary)
            Text("Drop files or folders here").font(.title3.weight(.semibold))
            Text("You can also drop them on the MyOpenCleaner icon in the Dock.").font(.callout).foregroundStyle(.secondary)
            Button("Choose…", action: choose)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
            .foregroundStyle(targeted ? .red : .secondary.opacity(0.5)))
        .padding(30)
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in ShredderQueue.shared.add([url]) }
            }
        }
        return !providers.isEmpty
    }

    func choose() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.prompt = "Add"
        if p.runModal() == .OK { queue.add(p.urls) }
    }

    func measure() {
        let missing = queue.items.filter { sizes[$0.path] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let measured = await AppState.background { missing.map { ($0.path, FileSize.of($0)) } }
            for (p, s) in measured { sizes[p] = s }
        }
    }

    func shred() {
        busy = true
        let targets = queue.items, env = state.env, n = passes
        Task {
            let r = await AppState.background {
                Shredder(env: env, passes: n).shred(targets) { url in
                    Task { @MainActor in current = url.lastPathComponent }
                }
            }
            state.record(.shredder, r)
            let failed = Set(r.failed.map(\.url.path))
            queue.items = queue.items.filter { failed.contains($0.path) }
            message = cleanSummary(r)
            busy = false
        }
    }
}
