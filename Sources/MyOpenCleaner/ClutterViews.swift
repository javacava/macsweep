import SwiftUI
import SweepCore

/// A generic "scan a folder, list files, delete chosen" page used by Large & Old and Cloud.
struct LargeOldView: View {
    @ObservedObject var state = AppState.shared
    @State private var files: [FileEntry]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var minMB = 100.0
    @State private var onlyOld = false
    @State private var kind: FileKind?
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    var shown: [FileEntry] { (files ?? []).filter { kind == nil || $0.kind == kind } }
    var chosen: [FileEntry] { (files ?? []).filter { selected.contains($0.id) } }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = chosen.map(\.url)
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .largeOld, subtitle: "Large files, and files you have not opened for over a year, in your home folder.") {
            HStack {
                Text("From")
                Picker("", selection: $minMB) {
                    ForEach([10.0, 50, 100, 500, 1000], id: \.self) { Text("\(Int($0)) MB").tag($0) }
                }.frame(width: 90)
                Toggle("Older than a year", isOn: $onlyOld).toggleStyle(.checkbox)
                Button("Scan", action: scan).disabled(busy)
            }
        } content: {
            if let files {
                VStack(spacing: 0) {
                    Picker("", selection: $kind) {
                        Text("All").tag(FileKind?.none)
                        ForEach(FileKind.allCases, id: \.self) { k in
                            if files.contains(where: { $0.kind == k }) { Text(k.title).tag(FileKind?.some(k)) }
                        }
                    }
                    .pickerStyle(.segmented).padding(8)
                    List(shown) { f in
                        FileRow(isOn: member($selected, f.id), url: f.url,
                                detail: state.display(f.url.deletingLastPathComponent()) + (f.accessed.map { " · opened " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""),
                                size: f.size)
                    }
                    ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.size },
                              buttonTitle: "Remove", busy: busy) { askConfirm() }
                }
            } else {
                StateView(symbol: "doc.badge.clock", title: busy ? "Scanning your home folder…" : "Find what takes up space",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, files == nil, !busy { scan() } }
        .confirmationDialog("Remove \(chosen.count) files?", isPresented: $confirm) {
            Button("Remove", role: .destructive) { remove(chosen.map { ($0.url, $0.size) }) }
        } message: { if let inUse { Text(inUse) } }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; files = nil
        let env = state.env, min = Int64(minMB * 1_048_576), old = onlyOld
        Task {
            files = await AppState.background { LargeOldFinder(env: env).find(minSize: min, olderThanDays: old ? 365 : nil) }
            selected = []; busy = false
        }
    }

    func remove(_ targets: [(url: URL, size: Int64)]) {
        busy = true
        let cleaner = state.cleaner()
        Task {
            let r = await AppState.background { cleaner.remove(targets) }
            state.record(.largeOld, r)
            message = cleanSummary(r)
            let gone = Set(r.removed.map(\.path))
            files?.removeAll { gone.contains($0.url.path) }
            selected.subtract(gone)
            busy = false
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var state = AppState.shared
    @State private var groups: [DuplicateGroup]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var folder: URL?
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    var all: [FileEntry] { groups?.flatMap(\.files) ?? [] }
    var chosen: [FileEntry] { all.filter { selected.contains($0.id) } }
    /// Never let the user delete every copy in a group.
    var unsafe: Bool { groups?.contains { g in g.files.allSatisfy { selected.contains($0.id) } } ?? false }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = chosen.map(\.url)
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .duplicates, subtitle: "Files with identical contents (SHA-256), whatever their names.") {
            Button(folder.map { "Folder: \($0.lastPathComponent)" } ?? "Choose folder…", action: chooseFolder)
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let groups {
                if groups.isEmpty { StateView(symbol: "checkmark.seal", title: "No duplicates found") } else {
                    VStack(spacing: 0) {
                        List {
                            ForEach(groups) { g in
                                Section {
                                    ForEach(g.files) { f in FileRow(isOn: member($selected, f.id), url: f.url, size: f.size) }
                                } header: {
                                    HStack { Text("\(g.files.count) copies · \(g.files[0].url.lastPathComponent)"); Spacer(); Text("wasted: \(FileSize.format(g.wasted))") }
                                }
                            }
                        }
                        HStack {
                            Button("Select suggested") { selected = Set(groups.flatMap(\.suggestedRemovals).map(\.id)) }
                                .help("Keeps the oldest copy in each group")
                            Button("Deselect all") { selected = [] }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.top, 6)
                        if unsafe {
                            Text("Every copy in a group is selected. Keep at least one.").foregroundStyle(.red).padding(6)
                        }
                        ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.size },
                                  buttonTitle: "Remove copies", busy: busy || unsafe) { askConfirm() }
                    }
                }
            } else {
                StateView(symbol: "doc.on.doc", title: busy ? "Comparing files…" : "Find identical files",
                          message: "By default, your whole home folder except ~/Library.", busy: busy,
                          buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, groups == nil, !busy { scan() } }
        .confirmationDialog("Remove \(chosen.count) copies?", isPresented: $confirm) {
            Button("Remove", role: .destructive, action: remove)
        } message: { if let inUse { Text(inUse) } }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        if p.runModal() == .OK { folder = p.url }
    }

    func scan() {
        busy = true; groups = nil
        let env = state.env, root = folder ?? env.home
        Task {
            let g = await AppState.background {
                let files = FileWalker(skip: [env.home.appendingPathComponent("Library")]).files(under: root, minSize: 1)
                return DuplicateFinder.find(in: files, minSize: 1024)
            }
            groups = g
            selected = []   // nothing is chosen for the user: identical files in two projects may both be needed
            busy = false
        }
    }

    func remove() {
        busy = true
        let targets = chosen.map { ($0.url, $0.size) }
        let cleaner = state.cleaner()
        Task {
            let r = await AppState.background { cleaner.remove(targets) }
            state.record(.duplicates, r)
            message = cleanSummary(r)
            busy = false
            scan()
        }
    }
}

struct SimilarView: View {
    @ObservedObject var state = AppState.shared
    @State private var groups: [[FileEntry]]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var folder: URL?
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    var chosen: [FileEntry] { (groups ?? []).flatMap { $0 }.filter { selected.contains($0.id) } }

    /// Checks whether running programs hold any of the files, then asks for confirmation.
    func askConfirm() {
        let urls: [URL] = chosen.map(\.url)
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    var body: some View {
        ModulePage(module: .similar, subtitle: "Similar photos: bursts, retakes, resized copies. The pictures are compared, not the files.") {
            Button(folder.map { "Folder: \($0.lastPathComponent)" } ?? "Choose folder…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK { folder = p.url }
            }
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let groups {
                if groups.isEmpty { StateView(symbol: "checkmark.seal", title: "No similar photos found") } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(groups, id: \.first!.id) { g in
                                    ScrollView(.horizontal) {
                                        HStack {
                                            ForEach(g) { f in thumb(f) }
                                        }
                                    }
                                }
                            }
                            .padding()
                        }
                        Text("Similarity is a guess and can be wrong. Look at the photos before removing any.")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.size },
                                  buttonTitle: "Remove", busy: busy) { askConfirm() }
                    }
                }
            } else {
                StateView(symbol: "photo.on.rectangle", title: busy ? "Analyzing images…" : "Find similar photos",
                          message: "By default, your Pictures, Downloads and Desktop folders.", busy: busy,
                          buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, groups == nil, !busy { scan() } }
        .confirmationDialog("Remove \(chosen.count) photos?", isPresented: $confirm) {
            Button("Remove", role: .destructive, action: remove)
        } message: { if let inUse { Text(inUse) } }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func thumb(_ f: FileEntry) -> some View {
        let on = selected.contains(f.id)
        return VStack {
            AsyncThumb(url: f.url).frame(width: 150, height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.red : .clear, lineWidth: 3))
            Toggle(f.url.lastPathComponent, isOn: member($selected, f.id)).toggleStyle(.checkbox).font(.caption).lineLimit(1).frame(width: 150)
            SizeText(bytes: f.size).font(.caption2)
        }
    }

    func scan() {
        busy = true; groups = nil
        let env = state.env
        let roots = folder.map { [$0] } ?? ["~/Pictures", "~/Downloads", "~/Desktop"].map(env.resolve)
        Task {
            let g = await AppState.background {
                let files = roots.flatMap { FileWalker().files(under: $0, minSize: 20_000) }.filter { $0.kind == .image }
                return SimilarImages.groups(files)
            }
            groups = g
            selected = []   // "similar" is a guess: the user picks what goes
            busy = false
        }
    }

    func remove() {
        busy = true
        let targets = chosen.map { ($0.url, $0.size) }
        let cleaner = state.cleaner()
        Task {
            let r = await AppState.background { cleaner.remove(targets) }
            state.record(.similar, r)
            message = cleanSummary(r)
            busy = false
            scan()
        }
    }
}

struct AsyncThumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .task {
            let u = url
            let data = await AppState.background { () -> Data? in
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 300,
                                                                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil }
                return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            }
            if let data { image = NSImage(data: data) }
        }
    }
}

struct SpaceMapView: View {
    @ObservedObject var state = AppState.shared
    @State private var stack: [DiskNode] = []
    @State private var busy = false
    @State private var message: String?
    @State private var confirmNode: DiskNode?

    var current: DiskNode? { stack.last }

    var body: some View {
        ModulePage(module: .spaceMap, subtitle: "A map of your disk: which folders are biggest. Click a folder to step inside.") {
            Button("Choose folder…") {
                let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                if p.runModal() == .OK, let u = p.url { load(u, reset: true) }
            }
            Button("Home folder") { load(state.env.home, reset: true) }.disabled(busy)
        } content: {
            if busy {
                StateView(symbol: "", title: "Measuring sizes…", busy: true)
            } else if let node = current {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { if stack.count > 1 { stack.removeLast() } } label: { Image(systemName: "chevron.left") }
                            .disabled(stack.count < 2)
                        Text(state.display(node.url)).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        SizeText(bytes: node.size)
                    }
                    .padding(10)
                    BubbleMap(node: node, open: open, remove: { confirmNode = $0 })
                        .padding(10)
                }
            } else {
                StateView(symbol: "circle.hexagongrid", title: "See what fills your disk",
                          buttonTitle: "Scan home folder") { load(state.env.home, reset: true) }
            }
        }
        .onAppear { if AppState.shared.autoScan, stack.isEmpty, !busy { load(state.env.home, reset: true) } }
        .confirmationDialog("Remove \"\(confirmNode?.name ?? "")\"?", isPresented: Binding(get: { confirmNode != nil }, set: { if !$0 { confirmNode = nil } })) {
            Button("Remove", role: .destructive) {
                guard let n = confirmNode else { return }
                let r = state.cleaner().remove([(n.url, n.size)])
                state.record(.spaceMap, r)
                message = cleanSummary(r)
                if let top = stack.last { load(top.url, reset: false, replace: true) }
            }
        }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func open(_ n: DiskNode) {
        guard n.isDirectory else { AppState.reveal(n.url); return }
        if n.children.isEmpty { load(n.url, reset: false) } else { stack.append(n) }
    }

    func load(_ url: URL, reset: Bool, replace: Bool = false) {
        busy = true
        Task {
            let n = await AppState.background { SpaceMap.build(url, depth: 2) }
            if reset { stack = [n] } else if replace { stack[stack.count - 1] = n } else { stack.append(n) }
            busy = false
        }
    }
}

/// Grid of bubbles sized by folder size.
struct BubbleMap: View {
    let node: DiskNode
    let open: (DiskNode) -> Void
    let remove: (DiskNode) -> Void
    let palette: [Color] = [.teal, .blue, .indigo, .purple, .pink, .orange, .green, .mint, .cyan]

    var body: some View {
        let (shown, other) = SpaceMap.top(node, limit: 24)
        let maxSize = Double(shown.first?.size ?? 1)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, child in
                    let scale = 0.45 + 0.55 * sqrt(Double(child.size) / max(maxSize, 1))
                    VStack(spacing: 4) {
                        Circle()
                            .fill(palette[i % palette.count].gradient)
                            .frame(width: 130 * scale, height: 130 * scale)
                            .overlay {
                                VStack(spacing: 2) {
                                    Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill")
                                    Text(FileSize.format(child.size)).font(.caption.bold().monospacedDigit())
                                }.foregroundStyle(.white)
                            }
                            .frame(width: 130, height: 130)
                        Text(child.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(String(format: "%.1f%%", child.fraction(of: node) * 100)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(child) }
                    .contextMenu {
                        Button("Show in Finder") { AppState.reveal(child.url) }
                        Button("Remove…", role: .destructive) { remove(child) }
                    }
                }
            }
            if other > 0 {
                Text("Other: \(FileSize.format(other))").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }
}

struct CloudView: View {
    @ObservedObject var state = AppState.shared
    @State private var files: [CloudFile]?
    @State private var selected = Set<String>()
    @State private var busy = false
    @State private var message: String?

    var chosen: [CloudFile] { files?.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        ModulePage(module: .cloud, subtitle: "Large iCloud Drive, Dropbox, Google Drive and OneDrive files stored locally. Keep them in the cloud only.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let files {
                if files.isEmpty { StateView(symbol: "checkmark.icloud", title: "No large local copies") } else {
                    VStack(spacing: 0) {
                        List(files) { f in
                            FileRow(isOn: member($selected, f.id), url: f.entry.url, detail: f.provider.rawValue, size: f.entry.size)
                        }
                        ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.entry.size },
                                  buttonTitle: "Keep in cloud only", busy: busy, action: evict)
                    }
                }
            } else {
                StateView(symbol: "icloud", title: busy ? "Scanning cloud folders…" : "Free up space without deleting files from the cloud",
                          busy: busy, buttonTitle: busy ? nil : "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, files == nil, !busy { scan() } }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func scan() {
        busy = true; files = nil
        let env = state.env
        Task { files = await AppState.background { CloudScanner(env: env).scan() }; selected = []; busy = false }
    }

    func evict() {
        var freed: Int64 = 0, ok = 0, failed: [String] = []
        for f in chosen where f.provider == .iCloud {
            do { try CloudScanner.evict(f.entry.url); freed += f.entry.size; ok += 1 } catch { failed.append(f.entry.url.lastPathComponent) }
        }
        let others = chosen.filter { $0.provider != .iCloud }
        if !others.isEmpty {
            // Third-party File Provider clients expose "Remove Download" in Finder; open the files there.
            NSWorkspace.shared.activateFileViewerSelecting(others.map(\.entry.url))
        }
        if freed > 0 {
            state.activity.record(module: Module.cloud.title, freed: freed, items: ok)
            state.activityVersion += 1
        }
        message = "iCloud: freed \(FileSize.format(freed)) (\(ok) files)."
            + (others.isEmpty ? "" : "\nFiles from other services are shown in Finder: choose Remove Download there.")
            + (failed.isEmpty ? "" : "\nFailed: \(failed.joined(separator: ", "))")
        scan()
    }
}
