import SwiftUI
import SweepCore

// MARK: - Page

/// Everything the cleanup scanners find, drawn as three rings: areas inside, the tools and apps that made
/// the files around them, and a thin outer band that shows how much of each is safe, needs a look, or stays.
struct StorageView: View {
    @ObservedObject var state = AppState.shared
    @State private var overview: StorageOverview?
    @State private var disk: DiskStats?
    @State private var busy = false
    @State private var progress = ""
    @State private var focus: Focus = .all
    @State private var selected = Set<String>()
    @State private var inUse: String?
    @State private var confirm = false
    @State private var message: String?

    enum Focus: Hashable {
        case all
        case area(SupportedTools.Area)
        case owner(String)
    }

    var allItems: [StorageOverview.Item] { overview?.owners.flatMap(\.items) ?? [] }
    var chosen: [StorageOverview.Item] { allItems.filter { selected.contains($0.id) && $0.isRemovable } }

    var body: some View {
        ModulePage(module: .storage, subtitle: "Everything the cleanup pages find, by the tool, app or project that made it. Click a ring to look inside.") {
            Button("Scan", action: scan).disabled(busy)
        } content: {
            if let overview, !busy || !overview.owners.isEmpty {
                if overview.owners.isEmpty {
                    StateView(symbol: "checkmark.seal", title: "Nothing to clean", message: "No caches, models or builds worth showing.")
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ScrollView {
                                VStack(spacing: 18) {
                                    StorageRings(overview: overview, focus: $focus)
                                        .frame(width: 480, height: 330)
                                        .padding(.top, 14)
                                    AreaLegend(overview: overview, focus: $focus)
                                    if let disk { DiskShare(disk: disk, overview: overview) }
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity)
                            }
                            .frame(minWidth: 500)
                            Divider()
                            StoragePanel(overview: overview, focus: $focus, selected: $selected)
                                .frame(minWidth: 380, maxWidth: .infinity)
                        }
                        ActionBar(selectedCount: chosen.count, selectedSize: chosen.reduce(0) { $0 + $1.size },
                                  buttonTitle: "Clean", busy: busy) { askConfirm() }
                    }
                }
            } else if busy {
                StateView(symbol: "", title: "Scanning…", message: progress, busy: true)
            } else {
                StateView(symbol: "chart.pie", title: "See where your space goes",
                          message: "One scan of system junk, developer tools, AI models and project builds, sorted by what made them. Nothing is selected or removed until you choose.",
                          buttonTitle: "Scan", action: scan)
            }
        }
        .onAppear { if AppState.shared.autoScan, overview == nil, !busy { scan() } }
        .onReceive(TourDriver.shared.$focus) { f in
            if let f { withAnimation(.spring(response: 0.45)) { focus = f } }
        }
        .confirmationDialog("Clean \(FileSize.format(chosen.reduce(0) { $0 + $1.size }))?", isPresented: $confirm) {
            Button("Clean", role: .destructive, action: clean)
        } message: {
            let review = chosen.filter { $0.safety == .review }.count
            Text((inUse.map { $0 + "\n\n" } ?? "") + "\(chosen.count) items."
                 + (review > 0 ? " \(review) of them are marked Check first: they may hold your own work." : ""))
        }
        .alert("Done", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: { Text(message ?? "") }
    }

    func askConfirm() {
        let urls = chosen.flatMap(\.paths)
        Task {
            inUse = await AppState.shared.inUseWarning(urls)
            confirm = true
        }
    }

    func scan() {
        busy = true
        let env = state.env, runner = state.runner
        Task {
            progress = "System junk…"
            let junk = await AppState.background { JunkScanner(env: env).scan().items }
            progress = "Developer tools and AI models…"
            let dev = await AppState.background { DevFolderScanner(env: env).scan() + SimulatorScanner(env: env, runner: runner).scan() }
            progress = "Project builds…"
            let builds = await AppState.background { BuildArtifactFinder(env: env, runner: runner).find() }
            let result = await AppState.background { StorageOverview.build(junk: junk, dev: dev + builds) }
            disk = Demo.active?.disk ?? SystemMonitor.disk()
            selected = []
            focus = .all
            overview = result
            busy = false
            // Screenshots: open the biggest tool so the side panel shows items and their marks.
            if Demo.active != nil, !TourDriver.shared.active, let top = result.owners.first(where: { $0.area == .ai }) ?? result.owners.first {
                focus = .owner(top.id)
            }
        }
    }

    func clean() {
        busy = true
        let items = chosen, env = state.env, runner = state.runner, cleaner = state.cleaner()
        Task {
            let report = await AppState.background { () -> CleanReport in
                var junk: [JunkItem] = [], dev: [DevItem] = []
                for item in items {
                    switch item { case .junk(let j): junk.append(j); case .dev(let d): dev.append(d) }
                }
                var r = cleaner.remove(junk)
                r.merge(DevCleaner(env: env, runner: runner, cleaner: cleaner).remove(dev))
                return r
            }
            state.record(.storage, report)
            message = cleanSummary(report)
            busy = false
            scan()
        }
    }
}

// MARK: - Colors

extension SupportedTools.Area {
    /// Hue of the area's ring; its tools are lighter and darker shades of it.
    var hue: Double {
        switch self {
        case .ai: 0.74
        case .developer: 0.6
        case .projects: 0.5
        case .apps: 0.92
        case .macOS: 0.66
        }
    }

    var saturation: Double { self == .macOS ? 0.18 : 0.62 }

    var color: Color { Color(hue: hue, saturation: saturation, brightness: 0.92) }

    /// The i-th tool's shade within the area.
    func shade(_ i: Int, of n: Int) -> Color {
        let t = n > 1 ? Double(i) / Double(n - 1) : 0
        return Color(hue: hue + (t - 0.5) * 0.06, saturation: saturation * (0.75 + 0.35 * t), brightness: 0.98 - 0.36 * t)
    }

    var shortTitle: String {
        switch self {
        case .ai: "AI"
        case .developer: "Developer"
        case .projects: "Projects"
        case .apps: "Apps"
        case .macOS: "macOS"
        }
    }
}

// MARK: - Rings

/// Geometry of the tilted disc: a ring seen from above at an angle. `tilt` 1 is straight down, smaller is flatter.
struct DiscGeometry {
    var tilt: Double
    var depth: Double

    /// Angle in degrees, clockwise from twelve o'clock.
    func point(_ c: CGPoint, _ r: CGFloat, _ angle: Double) -> CGPoint {
        let a = angle * .pi / 180
        return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a) * tilt)
    }

    func arc(_ c: CGPoint, _ r: CGFloat, from a: Double, to b: Double) -> [CGPoint] {
        let steps = max(Int(abs(b - a) / 1.5), 1)
        return (0...steps).map { point(c, r, a + (b - a) * Double($0) / Double(steps)) }
    }
}

/// The top face of one slice of the disc. Animates its angles, tilt and depth.
struct DiscTop: Shape {
    var start: Double, end: Double, tilt: Double, depth: Double
    let inner: CGFloat, outer: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(tilt, depth)) }
        set { start = newValue.first.first; end = newValue.first.second; tilt = newValue.second.first; depth = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard end > start else { return p }
        let g = DiscGeometry(tilt: tilt, depth: depth), c = CGPoint(x: rect.midX, y: rect.midY - depth / 2)
        p.addLines(g.arc(c, outer, from: start, to: end) + g.arc(c, inner, from: end, to: start))
        p.closeSubpath()
        return p
    }
}

/// The walls under a slice: outer rim, inner rim and both cut ends, `depth` points tall.
struct DiscWalls: Shape {
    var start: Double, end: Double, tilt: Double, depth: Double
    let inner: CGFloat, outer: CGFloat
    /// The cut ends show only on a raised slice; on the others they would draw stripes between neighbours.
    var caps = false
    /// How much taller the walls are than the disc: a raised slice stands on the floor like a column.
    var extra = 0.0

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, AnimatablePair<Double, Double>>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(tilt, AnimatablePair(depth, extra))) }
        set {
            start = newValue.first.first; end = newValue.first.second
            tilt = newValue.second.first; depth = newValue.second.second.first; extra = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard end > start, depth > 0.1 else { return p }
        let g = DiscGeometry(tilt: tilt, depth: depth), c = CGPoint(x: rect.midX, y: rect.midY - depth / 2)
        func down(_ pts: [CGPoint]) -> [CGPoint] { pts.map { CGPoint(x: $0.x, y: $0.y + depth + extra) } }
        for r in [outer, inner] {
            let top = g.arc(c, r, from: start, to: end)
            p.addLines(top + down(top).reversed())
            p.closeSubpath()
        }
        for a in [start, end] where caps {
            let q = [g.point(c, inner, a), g.point(c, outer, a)]
            p.addLines(q + down(q).reversed())
            p.closeSubpath()
        }
        return p
    }
}

struct StorageRings: View {
    let overview: StorageOverview
    @Binding var focus: StorageView.Focus
    @State private var grow = 0.0
    @State private var hovered: String?
    @ObservedObject private var tour = TourDriver.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Slice: Identifiable {
        let id: String
        let start: Double
        let end: Double
        let color: Color
        let ring: Int           // 0 areas, 1 tools, 2 safety rim
        let area: SupportedTools.Area
        let ownerID: String?
        /// The area's and the tool's whole arc: raised slices move together along it.
        var areaArc: ClosedRange<Double> = 0...0
        var ownerArc: ClosedRange<Double> = 0...0
        var mid: Double { (start + end) / 2 }
    }

    static let gap = 0.9                 // degrees between slices
    static let tilt = 0.5                // how flat the disc lies
    static let depth = 26.0              // wall height in points
    static let radii: [(CGFloat, CGFloat)] = [(104, 148), (153, 205), (209, 219)]

    /// Shares of `total` degrees, each at least `minimum` so small things stay visible and clickable.
    static func spans(_ sizes: [Int64], total: Double, minimum: Double) -> [Double] {
        let sum = Double(max(sizes.reduce(0, +), 1))
        let raw = sizes.map { total * Double($0) / sum }
        let floor = min(minimum, total / Double(max(sizes.count, 1)))
        let small = raw.filter { $0 < floor }.count
        let bigSum = raw.filter { $0 >= floor }.reduce(0, +)
        let left = total - Double(small) * floor
        return raw.map { $0 < floor ? floor : (bigSum > 0 ? $0 / bigSum * left : floor) }
    }

    var slices: [Slice] {
        var out: [Slice] = []
        var angle = 0.0
        let areas = overview.areas
        let areaSpans = Self.spans(areas.map { overview.size(of: $0) }, total: 360, minimum: 20)
        for (area, span) in zip(areas, areaSpans) {
            let areaArc = angle...(angle + span)
            out.append(Slice(id: "area:" + area.rawValue, start: angle, end: angle + span, color: area.color, ring: 0, area: area,
                             ownerID: nil, areaArc: areaArc))
            let owners = overview.ringOwners(in: area)
            let ownerSpans = Self.spans(owners.map(\.size), total: span, minimum: 3.5)
            var a = angle
            for (i, o) in owners.enumerated() {
                let s = ownerSpans[i]
                let ownerArc = a...(a + s)
                out.append(Slice(id: "owner:" + o.id, start: a, end: a + s, color: area.shade(i, of: owners.count),
                                 ring: 1, area: area, ownerID: o.id, areaArc: areaArc, ownerArc: ownerArc))
                // The rim: the tool's share that is safe, to check, and kept, in that order.
                var b = a
                for safety in Safety.allCases {
                    let part = s * Double(o.size(safety)) / Double(max(o.size, 1))
                    if part > 0.05 {
                        out.append(Slice(id: "rim:\(o.id):\(safety.rawValue)", start: b, end: b + part, color: safety.ringColor,
                                         ring: 2, area: area, ownerID: o.id, areaArc: areaArc, ownerArc: ownerArc))
                    }
                    b += part
                }
                a += s
            }
            angle += span
        }
        return out
    }

    func isDimmed(_ s: Slice) -> Bool { isDimmed(s, focus: focus) }

    func isDimmed(_ s: Slice, focus: StorageView.Focus) -> Bool {
        switch focus {
        case .all: false
        case .area(let a): s.area != a
        case .owner(let id): s.ring == 0 ? overview.owners.first { $0.id == id }?.area != s.area && !Self.isOther(id, s.area) : s.ownerID != id
        }
    }

    static func isOther(_ id: String, _ area: SupportedTools.Area) -> Bool { id == area.rawValue + "/Other" }

    enum Raise { case none, area, owner }

    /// What lifts: a whole area (all three rings of it, so nothing slides over a neighbour), or one tool with its rim.
    func raise(_ s: Slice) -> Raise { raise(s, hover: currentHover, focus: focus) }

    func raise(_ s: Slice, hover: String?, focus: StorageView.Focus) -> Raise {
        if let h = hover {
            if h == "area:" + s.area.rawValue { return .area }
            if s.ring != 0, let o = s.ownerID, h == "owner:" + o || h.hasPrefix("rim:" + o + ":") { return .owner }
        }
        switch focus {
        case .all: return .none
        case .area(let a): return s.area == a ? .area : .none
        case .owner(let id): return s.ownerID == id ? .owner : .none
        }
    }

    func isRaised(_ s: Slice) -> Bool { lift(s) > 0.001 }

    // While recording (`--record`) the script drives the disc on a clock of its own, one video frame at a time,
    // so the video is smooth however long each frame takes to capture. Otherwise SwiftUI animates as usual.
    var currentHover: String? { tour.active ? tour.hover : hovered }
    var g: Double { tour.active ? tour.grow : grow }

    /// How far a slice is lifted, 0…1.
    func lift(_ s: Slice) -> Double {
        let now = raise(s) != .none
        guard tour.active, let c = tour.change else { return now ? 1 : 0 }
        let before = raise(s, hover: c.hover, focus: c.focus) != .none
        guard before != now else { return now ? 1 : 0 }
        let p = TourDriver.easeOutBack(min((tour.clock - c.time) / 0.38, 1))
        return now ? p : 1 - p
    }

    /// How far a slice is dimmed, 0…1.
    func dimAmount(_ s: Slice) -> Double {
        let now = isDimmed(s)
        guard tour.active, let c = tour.change else { return now ? 1 : 0 }
        let before = isDimmed(s, focus: c.focus)
        guard before != now else { return now ? 1 : 0 }
        let p = min((tour.clock - c.time) / 0.25, 1)
        return now ? p : 1 - p
    }

    /// The direction a lifted slice moves: as it is raised now, or as it was while it settles back.
    func raiseMode(_ s: Slice) -> Raise {
        let now = raise(s)
        if now != .none || !tour.active { return now }
        guard let c = tour.change else { return .none }
        return raise(s, hover: c.hover, focus: c.focus)
    }

    var body: some View {
        let all = slices
        GeometryReader { geo in
        ZStack {
            OrbitBackdrop(radius: 236, tilt: Self.tilt + (1 - Self.tilt) * (1 - g), clock: tour.active ? tour.clock : nil)
                .offset(y: Self.depth * g / 2)
            // Walls first, then the top faces over them: the tops all lie in one plane and never overlap,
            // so a big slice can never paint over its neighbours. Raised slices go above everything.
            ForEach(all) { s in
                wedge(s, part: .walls).zIndex(zOrder(s, part: .walls))
                wedge(s, part: .top).zIndex(zOrder(s, part: .top))
            }
            CenterLabel(overview: overview, focus: focus, override: summary(currentHover))
                .frame(width: 170)
                .offset(y: -Self.depth * g / 2 + 6)
                .opacity(min(g, 1))
                .zIndex(10_000)
                .allowsHitTesting(false)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let id = hit(p, in: geo.size, slices: all)?.id
                if id != hovered { hovered = id }
                (id == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
            case .ended:
                hovered = nil
                NSCursor.arrow.set()
            }
        }
        .gesture(SpatialTapGesture().onEnded { tap in
            if let s = hit(tap.location, in: geo.size, slices: all) { select(s) }
        })
        }
        .rotationEffect(.degrees(reduceMotion ? 0 : (1 - g) * -30))
        .onAppear(perform: animateIn)
        .onChange(of: overview.size) { _, _ in grow = 0; animateIn() }
        .transaction { t in if TourDriver.shared.active { t.animation = nil; t.disablesAnimations = true } }
    }

    enum Part { case walls, top }

    /// Layers: walls (inner rings first, so the outer rim's wall is in front below the disc), then top faces,
    /// then whatever is raised, again walls under tops.
    func zOrder(_ s: Slice, part: Part) -> Double {
        let r = Double(Self.radii[s.ring].0 + Self.radii[s.ring].1) / 2
        let y = -cos(s.mid * .pi / 180) * r + 300          // 0…600, back to front
        let base: Double = isRaised(s) ? 20_000 : 0
        switch part {
        case .walls: return base + Double(s.ring) * 1_000 + y
        case .top: return base + 10_000 + y
        }
    }

    func animateIn() {
        if reduceMotion { grow = 1; return }
        withAnimation(.spring(response: 1.4, dampingFraction: 0.82)) { grow = 1 }
    }

    @ViewBuilder func wedge(_ s: Slice, part: Part) -> some View {
        let (inner, outer) = Self.radii[s.ring]
        let span = max(s.end - s.start - (s.ring == 2 ? 0.25 : Self.gap), 0)
        let start = s.start + (s.end - s.start - span) / 2
        let gv = g
        let end = start + span * min(gv, 1.02)
        let tilt = Self.tilt + (1 - Self.tilt) * (1 - gv)     // lies down as it appears
        let depth = (s.ring == 2 ? Self.depth * 0.8 : Self.depth) * gv
        let mode = raiseMode(s)
        let l = lift(s)
        let raised = l > 0.001
        let dim = isDimmed(s)
        let d = tour.active ? dimAmount(s) : (dim ? 1 : 0)
        // Everything raised together moves along the same direction: the middle of its area or of its tool.
        let arc = mode == .area ? s.areaArc : s.ownerArc
        let midRad = (arc.lowerBound + arc.upperBound) / 2 * .pi / 180
        // A slice wider than half the disc only rises; sliding it sideways would look like the disc breaking.
        let slide: CGFloat = arc.upperBound - arc.lowerBound < 180 ? 9 * l : 0
        let rise: CGFloat = 14 * l
        // A raised slice is drawn above everything, so its walls must stop where something would hide them:
        // a tool lifted at the back of the disc has the inner ring in front of it, so its walls end at the
        // disc's surface; anywhere else nothing is in front, and they reach the bottom of the disc.
        let behindInner = s.ring > 0 && mode == .owner && cos(s.mid * .pi / 180) > 0
        let extra = raised ? (behindInner ? Double(rise) - depth : Double(rise)) : 0
        ZStack {
            if part == .walls {
                DiscWalls(start: start, end: end, tilt: tilt, depth: depth, inner: inner, outer: outer, caps: raised, extra: extra)
                    .fill(s.color)
                    .overlay(DiscWalls(start: start, end: end, tilt: tilt, depth: depth, inner: inner, outer: outer, caps: raised, extra: extra)
                        .fill(LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: s.color.opacity(0.7 * min(l, 1)), radius: 14 * min(l, 1), y: 6 * min(l, 1))
            } else {
                // Opaque: a see-through top would let the walls underneath show as rings inside rings.
                DiscTop(start: start, end: end, tilt: tilt, depth: depth, inner: inner, outer: outer)
                    .fill(s.color)
                    .overlay(DiscTop(start: start, end: end, tilt: tilt, depth: depth, inner: inner, outer: outer)
                        .fill(LinearGradient(colors: [.white.opacity(0.1), .black.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                DiscTop(start: start, end: end, tilt: tilt, depth: depth, inner: inner, outer: outer)
                    .stroke(.white.opacity(0.16 + 0.54 * min(l, 1)), lineWidth: 0.6 + 0.8 * min(l, 1))
            }
        }
        // Dimmed slices stay opaque: see-through walls would show the disc's insides.
        .saturation(1 - 0.75 * d)
        .brightness(-0.22 * d)
        .offset(x: sin(midRad) * slide, y: -cos(midRad) * slide * Self.tilt - rise)
        .animation(.spring(response: 1.25, dampingFraction: 0.84).delay(Double(s.ring) * 0.1 + s.start / 360 * 0.35), value: grow)
        .animation(.spring(response: 0.34, dampingFraction: 0.62), value: raised)
        .animation(.easeInOut(duration: 0.25), value: dim)
        // The chart finds the slice under the pointer itself: every slice is a layer as big as the chart,
        // so per-slice hover would always go to the topmost (raised) one.
        .allowsHitTesting(false)
    }

    /// The slice under a point, from the disc's geometry: its top face, or the wall hanging below it.
    func hit(_ p: CGPoint, in size: CGSize, slices: [Slice]) -> Slice? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2 - Self.depth / 2)
        func probe(_ q: CGPoint) -> Slice? {
            let dx = Double(q.x - c.x), dy = Double(q.y - c.y) / Self.tilt
            let r = CGFloat((dx * dx + dy * dy).squareRoot())
            guard let ring = Self.radii.firstIndex(where: { r >= $0.0 - 2 && r <= $0.1 + 2 }) else { return nil }
            var angle = atan2(dx, -dy) * 180 / .pi
            if angle < 0 { angle += 360 }
            return slices.first { $0.ring == ring && angle >= $0.start && angle < $0.end }
        }
        for k in stride(from: 0.0, through: Self.depth, by: 2) {
            if let s = probe(CGPoint(x: p.x, y: p.y - k)) { return s }
        }
        return nil
    }

    func select(_ s: Slice) {
        withAnimation(.spring(response: 0.4)) {
            if s.ring == 0 { focus = focus == .area(s.area) ? .all : .area(s.area) }
            else if let id = s.ownerID { focus = focus == .owner(id) ? .area(s.area) : .owner(id) }
        }
    }

    /// Name, size and safe share of the slice under the pointer, for the middle of the disc.
    func summary(_ id: String?) -> (title: String, size: Int64, safe: Int64)? {
        guard let id, let s = slices.first(where: { $0.id == id }) else { return nil }
        if s.ring == 0 {
            return (s.area.title, overview.size(of: s.area), overview.owners(in: s.area).reduce(0) { $0 + $1.size(.safe) })
        }
        guard let o = overview.ringOwners(in: s.area).first(where: { $0.id == s.ownerID }) else { return nil }
        return (o.name, o.size, o.size(.safe))
    }
}

extension Safety {
    var ringColor: Color {
        switch self {
        case .safe: Color(red: 0.2, green: 0.82, blue: 0.55)
        case .review: Color(red: 1.0, green: 0.7, blue: 0.2)
        case .kept: Color(white: 0.6)
        }
    }
}

/// The number in the middle: what is in focus, and how much of it is safe to remove.
struct CenterLabel: View {
    let overview: StorageOverview
    let focus: StorageView.Focus
    /// What the pointer is over, shown instead of the focus while it is there.
    var override: (title: String, size: Int64, safe: Int64)? = nil

    var current: (title: String, size: Int64, safe: Int64) {
        switch focus {
        case .all: return ("Found", overview.size, overview.size(.safe))
        case .area(let a):
            let owners = overview.owners(in: a)
            return (a.title, overview.size(of: a), owners.reduce(0) { $0 + $1.size(.safe) })
        case .owner(let id):
            let o = overview.owners.first { $0.id == id }
                ?? overview.areas.lazy.compactMap { area in overview.ringOwners(in: area).first { $0.id == id } }.first
            return (o?.name ?? "", o?.size ?? 0, o?.size(.safe) ?? 0)
        }
    }

    var body: some View {
        let c = override ?? current
        VStack(spacing: 3) {
            Text(c.title).font(.callout.weight(.medium)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            Text(FileSize.format(c.size))
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(FileSize.format(c.safe)) safe")
                .font(.caption.weight(.medium)).foregroundStyle(Safety.safe.ringColor)
                .contentTransition(.numericText())
        }
        .animation(.spring(response: 0.45), value: c.size)
    }
}

/// A faint orbit with a few drifting points behind the rings.
struct OrbitBackdrop: View {
    let radius: CGFloat
    var tilt: Double = 1
    /// A recording's own clock; nil follows real time.
    var clock: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let clock { orbit(clock * 1.6) } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                orbit(context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    func orbit(_ t: Double) -> some View {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let ry = radius * tilt
                let orbit = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - ry, width: radius * 2, height: ry * 2))
                ctx.stroke(orbit, with: .color(.secondary.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                for i in 0..<3 {
                    let a = t * (0.12 + Double(i) * 0.05) + Double(i) * 2.1
                    let p = CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * ry)
                    let r: CGFloat = 2.5 - CGFloat(i) * 0.5
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(SupportedTools.Area.allCases[i].color.opacity(0.85)))
                }
                let glow = Gradient(colors: [Color.purple.opacity(0.10), .clear])
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - ry, width: radius * 2, height: ry * 2)),
                         with: .radialGradient(glow, center: c, startRadius: 0, endRadius: radius))
            }
    }
}

// MARK: - Legend and disk

struct AreaLegend: View {
    let overview: StorageOverview
    @Binding var focus: StorageView.Focus
    @State private var shown = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(overview.areas, id: \.self) { area in
                let share = Double(overview.size(of: area)) / Double(max(overview.size, 1))
                Button {
                    withAnimation(.spring(response: 0.4)) { focus = focus == .area(area) ? .all : .area(area) }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(area.color).frame(width: 10, height: 10)
                        Text(area.title).frame(width: 150, alignment: .leading)
                        GeometryReader { g in
                            Capsule().fill(.quaternary)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(area.color.gradient).frame(width: g.size.width * (shown ? share : 0))
                                }
                        }
                        .frame(height: 6)
                        SizeText(bytes: overview.size(of: area)).frame(width: 80, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .opacity(focus == .all || focus == .area(area) ? 1 : 0.55)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.3)) { shown = true } }
    }
}

/// The whole disk as one bar: what MyOpenCleaner found (safe, to check, kept), the rest in use, and free space.
struct DiskShare: View {
    let disk: DiskStats
    let overview: StorageOverview
    @State private var shown = false

    var body: some View {
        let total = Double(max(disk.total, 1))
        let parts: [(String, Int64, Color)] = [
            ("Safe to remove", overview.size(.safe), Safety.safe.ringColor),
            ("Check first", overview.size(.review), Safety.review.ringColor),
            ("Kept", overview.size(.kept), Safety.kept.ringColor),
            ("Everything else", max(disk.used - overview.size, 0), Color.secondary.opacity(0.35)),
        ]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your disk").font(.headline)
                Spacer()
                Text("\(FileSize.format(disk.available)) free of \(FileSize.format(disk.total))").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2.gradient)
                            .frame(width: max(g.size.width * Double(p.1) / total * (shown ? 1 : 0) - 1.5, 0))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(parts.prefix(3), id: \.0) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.2).frame(width: 7, height: 7)
                        Text("\(p.0) \(FileSize.format(p.1))").font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { withAnimation(.easeOut(duration: 1.2).delay(0.5)) { shown = true } }
    }
}

// MARK: - Side panel

struct StoragePanel: View {
    let overview: StorageOverview
    @Binding var focus: StorageView.Focus
    @Binding var selected: Set<String>

    var owners: [StorageOverview.Owner] {
        switch focus {
        case .all: overview.owners
        case .area(let a): overview.owners(in: a)
        case .owner: []
        }
    }

    var owner: StorageOverview.Owner? {
        guard case .owner(let id) = focus else { return nil }
        if let o = overview.owners.first(where: { $0.id == id }) { return o }
        // "Other" exists only in the rings.
        return overview.areas.lazy.compactMap { overview.ringOwners(in: $0).first { $0.id == id } }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let owner {
                List {
                    if owner.items.contains(where: { $0.safety == .safe }) {
                        Button("Select all safe in \(owner.name)") {
                            selected.formUnion(owner.items.filter { $0.safety == .safe }.map(\.id))
                        }
                        .controlSize(.small)
                    }
                    ForEach(owner.items.prefix(300)) { item in StorageItemRow(item: item, selected: $selected) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .id(owner.id)
            } else {
                List {
                    ForEach(owners) { o in
                        Button { withAnimation(.spring(response: 0.4)) { focus = .owner(o.id) } } label: { OwnerRow(owner: o) }
                            .buttonStyle(.plain)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder var header: some View {
        HStack(spacing: 6) {
            Button("All") { withAnimation(.spring(response: 0.4)) { focus = .all } }
                .buttonStyle(.link).disabled(focus == .all)
            switch focus {
            case .all:
                Text("· \(overview.owners.count) tools, apps and projects").foregroundStyle(.secondary)
            case .area(let a):
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                Text(a.title).fontWeight(.semibold)
            case .owner:
                if let o = owner {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Button(o.area.title) { withAnimation(.spring(response: 0.4)) { focus = .area(o.area) } }.buttonStyle(.link)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Text(o.name).fontWeight(.semibold).lineLimit(1)
                }
            }
            Spacer()
        }
        .font(.callout)
    }
}

/// A tool in the list: its name, area, a bar split by safety, and its size.
struct OwnerRow: View {
    let owner: StorageOverview.Owner

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(owner.area.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(owner.name).lineLimit(1)
                    Text("\(owner.items.count)").font(.caption).foregroundStyle(.secondary)
                }
                SafetyBar(owner: owner).frame(height: 4)
            }
            Spacer(minLength: 12)
            SizeText(bytes: owner.size)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

struct SafetyBar: View {
    let owner: StorageOverview.Owner
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(Safety.allCases, id: \.self) { s in
                    let w = g.size.width * Double(owner.size(s)) / Double(max(owner.size, 1))
                    if w > 0 { Capsule().fill(s.ringColor).frame(width: w) }
                }
            }
        }
    }
}

struct StorageItemRow: View {
    let item: StorageOverview.Item
    @Binding var selected: Set<String>

    var detail: String {
        switch item {
        case .junk(let j): return AppState.shared.display(j.url.deletingLastPathComponent())
        case .dev(let d): return d.detail
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if item.isRemovable {
                Toggle("", isOn: member($selected, item.id)).labelsHidden().toggleStyle(.checkbox)
            } else {
                Image(systemName: Safety.kept.symbol).foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            SafetyBadge(safety: item.safety)
            SizeText(bytes: item.size)
            if let url = item.location {
                Button { AppState.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
        .padding(.vertical, 2)
    }
}
