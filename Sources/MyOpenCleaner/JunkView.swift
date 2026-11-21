import SwiftUI
import SweepCore

struct JunkView: View {
    @ObservedObject var state = AppState.shared
    @State private var result: JunkScanResult?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var progress = ""
    @State private var expanded = Set<JunkCategory>()
    @State private var confirm = false
    @State private var message: String?

    var selectedItems: [JunkItem] { result?.items.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        ModulePage(module: .junk, subtitle: "Caches, logs, Xcode and developer junk, mail attachments, Trash, incomplete downloads.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if busy && result == nil {
                StateView(symbol: "", title: "Scanning…", message: progress, busy: true)
            } else if let result {
                if result.items.isEmpty {
                    StateView(symbol: "checkmark.seal", title: "No junk found", message: "Your Mac is clean.")
                } else {
                    VStack(spacing: 0) {
                        if !result.unreadable.isEmpty { fdaBanner(result.unreadable.count) }
                        List {
                            ForEach(result.categories) { cat in categorySection(cat, result) }
                        }
                        ActionBar(selectedCount: selectedItems.count, selectedSize: selectedItems.reduce(0) { $0 + $1.size },
                                  buttonTitle: "Clean", busy: busy) { confirm = true }
                    }
                }
            } else {
                StateView(symbol: "trash.circle", title: "Find hidden junk",
                          message: "Scanning removes nothing. You choose what to clean.",
                          buttonTitle: "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, result == nil, !busy { scan() } }
        .confirmationDialog("Clean \(FileSize.format(selectedItems.reduce(0) { $0 + $1.size }))?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: clean)
        } message: {
            Text("Apps rebuild the caches they need. Quit browsers before clearing their caches.")
        }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func categorySection(_ cat: JunkCategory, _ r: JunkScanResult) -> some View {
        let items = r.items(in: cat)
        let ids = Set(items.map(\.id))
        let all = Binding(get: { ids.isSubset(of: selected) },
                          set: { on in if on { selected.formUnion(ids) } else { selected.subtract(ids) } })
        return DisclosureGroup(isExpanded: Binding(get: { expanded.contains(cat) },
                                                   set: { if $0 { expanded.insert(cat) } else { expanded.remove(cat) } })) {
            ForEach(items.prefix(300)) { item in
                FileRow(isOn: member($selected, item.id), url: item.url, size: item.size)
            }
            if items.count > 300 { Text("…\(items.count - 300) more").foregroundStyle(.secondary) }
        } label: {
            HStack {
                Toggle("", isOn: all).labelsHidden().toggleStyle(.checkbox)
                Image(systemName: cat.symbol).frame(width: 22).foregroundStyle(Module.junk.tint)
                Text(cat.title).font(.headline)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SizeText(bytes: r.size(of: cat))
            }
        }
    }

    func fdaBanner(_ n: Int) -> some View {
        HStack {
            Image(systemName: "lock.shield").foregroundStyle(.orange)
            Text("\(n) folders are not readable. Give MyOpenCleaner Full Disk Access to find more.").font(.callout)
            Spacer()
            Button("Open Settings") { AppState.openFullDiskAccessSettings() }
        }
        .padding(10).background(.orange.opacity(0.1))
    }

    func scan() {
        busy = true
        result = nil
        let env = state.env
        Task {
            let r = await AppState.background { JunkScanner(env: env).scan() }
            result = r
            selected = r.defaultSelection
            busy = false
        }
    }

    func clean() {
        busy = true
        let items = selectedItems
        let cleaner = state.cleaner()
        Task {
            let report = await AppState.background { cleaner.remove(items) }
            state.record(.junk, report)
            message = cleanSummary(report)
            busy = false
            scan()
        }
    }
}
