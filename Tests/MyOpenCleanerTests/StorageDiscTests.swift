import Foundation
import Testing
@testable import MyOpenCleaner

/// The Storage disc's arithmetic: slice widths and the recording's animation curves.
@Suite struct StorageDiscTests {
    @Test func spansFillTheCircleAndKeepSmallThingsVisible() {
        let spans = StorageRings.spans([1_000_000, 10, 10, 5], total: 360, minimum: 20)
        #expect(abs(spans.reduce(0, +) - 360) < 0.0001)
        #expect(spans.dropFirst().allSatisfy { $0 == 20 }, "tiny areas get the minimum")
        #expect(spans[0] == 300)
    }

    @Test func spansWithMoreSlicesThanRoomShareEvenly() {
        let spans = StorageRings.spans(Array(repeating: 1, count: 10), total: 20, minimum: 3.5)
        #expect(spans.allSatisfy { abs($0 - 2) < 0.0001 })
        #expect(StorageRings.spans([0, 0], total: 90, minimum: 10).reduce(0, +) <= 90)
    }

    @Test func springSettlesAtOne() {
        #expect(TourDriver.spring(0) == 0)
        #expect(TourDriver.spring(-1) == 0)
        #expect(abs(TourDriver.spring(5) - 1) < 0.001)
        let peak = stride(from: 0.0, to: 3, by: 0.01).map { TourDriver.spring($0) }.max() ?? 0
        #expect(peak > 1 && peak < 1.1, "a little overshoot, like the app's spring")
    }

    @Test func easeOutBackEndsWhereItShould() {
        #expect(abs(TourDriver.easeOutBack(0)) < 0.0001)
        #expect(abs(TourDriver.easeOutBack(1) - 1) < 0.0001)
        #expect(TourDriver.easeOutBack(0.7) > 1, "overshoots before it settles")
    }

    @MainActor @Test func tourRemembersWhatCameBefore() {
        let tour = TourDriver()
        tour.clock = 2
        tour.point(at: "area:ai")
        tour.clock = 3
        tour.select(.area(.developer))
        #expect(tour.change?.time == 3 && tour.change?.hover == "area:ai" && tour.change?.focus == .all)
        #expect(tour.grow == 1, "no opening without replay")
        tour.replay()
        #expect(tour.grow == 0)
    }
}
