import SwiftUI
import AVFoundation
import SweepCore

/// Moves the Storage disc during a recording, on a clock of its own: what the pointer is over, what is
/// selected, and when the opening animation started.
@MainActor
final class TourDriver: ObservableObject {
    static let shared = TourDriver()
    var active = false
    /// Seconds of video recorded so far.
    @Published var clock = 0.0
    @Published private(set) var hover: String?
    @Published private(set) var focus: StorageView.Focus?
    @Published private(set) var replayAt: Double?
    /// The last change of pointer or selection, with what they were before, so slices can ease between the two.
    private(set) var change: (time: Double, hover: String?, focus: StorageView.Focus)?

    func point(at id: String?) {
        change = (clock, hover, focus ?? .all)
        hover = id
    }

    func select(_ f: StorageView.Focus) {
        change = (clock, hover, focus ?? .all)
        focus = f
    }

    func replay() { replayAt = clock }

    /// The disc's opening: a spring like the one the app uses.
    var grow: Double {
        guard let start = replayAt else { return 1 }
        return Self.spring(clock - start)
    }

    nonisolated static func spring(_ t: Double, response: Double = 1.4, damping: Double = 0.82) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * Double.pi / response, wd = w * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * w * t) * (cos(wd * t) + damping * w / wd * sin(wd * t))
    }

    /// Overshoots a little, then settles: the lift of a slice.
    nonisolated static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// `MyOpenCleaner --record <file.mp4> --demo [--dark]`: plays a short tour of the made-up demo Mac in a window
/// nobody sees, and writes it to a video. Nothing on the screen is captured, so the Mac stays usable meanwhile.
@MainActor
enum Recorder {
    static let size = CGSize(width: 1100, height: 720)
    static let scale: CGFloat = 2

    struct Step {
        let seconds: Double
        let record: Bool
        let action: () -> Void
    }

    static func run(to output: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        TourDriver.shared.active = true
        let dark = CommandLine.arguments.contains("--dark")

        // Invisible but on screen, so SwiftUI keeps animating: fully transparent, behind every window, click-through.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = NSHostingView(rootView: RootView().frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Recording")

        guard let writer = VideoWriter(url: output, width: Int(size.width * scale), height: Int(size.height * scale)) else {
            print("Could not create \(output.path)"); exit(1)
        }
        let background = dark ? CGColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
        let tour = TourDriver.shared
        func go(_ m: Module) { AppState.shared.selection = m }

        let steps: [Step] = [
            Step(seconds: 6, record: false) { go(.storage) },                      // scan the demo Mac
            Step(seconds: 2.4, record: true) { tour.replay() },                     // the disc rises
            Step(seconds: 1.0, record: true) { tour.point(at: "area:ai") },
            Step(seconds: 1.0, record: true) { tour.point(at: "owner:ai/Ollama") },
            Step(seconds: 1.0, record: true) { tour.point(at: "owner:apps/Slack") },
            Step(seconds: 1.0, record: true) { tour.point(at: "owner:projects/web-shop") },
            Step(seconds: 1.0, record: true) { tour.point(at: "area:macOS") },
            Step(seconds: 2.2, record: true) { tour.point(at: nil); tour.select(.owner("ai/Ollama")) },
            Step(seconds: 1.6, record: true) { tour.select(.area(.developer)) },
            Step(seconds: 1.0, record: true) { tour.select(.all) },
            Step(seconds: 5, record: false) { go(.developer) },
            Step(seconds: 2.4, record: true) {},
            Step(seconds: 5, record: false) { go(.junk) },
            Step(seconds: 2.2, record: true) {},
            Step(seconds: 3, record: false) { go(.monitor) },
            Step(seconds: 2.2, record: true) {},
            Step(seconds: 5, record: false) { go(.similar) },
            Step(seconds: 2.0, record: true) {},
        ]

        let fps = 30.0
        var index = -1
        var stepEnds = Date()          // waiting steps: wall clock
        var framesLeft = 0             // recording steps: video frames
        var frame = 0
        var previous: CGImage?
        var fadeFrom: CGImage?
        var fadeLeft = 0
        let fadeFrames = 10

        func capture() -> CGImage? {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.cgImage
        }

        func nextStep() {
            index += 1
            guard index < steps.count else {
                writer.finish {
                    ProcessInfo.processInfo.endActivity(activity)
                    Demo.active?.remove()
                    print("wrote \(output.path) (\(frame) frames)")
                    exit(0)
                }
                return
            }
            let step = steps[index]
            let wasRecording = index > 0 && steps[index - 1].record
            if step.record && !wasRecording, previous != nil { fadeFrom = previous; fadeLeft = fadeFrames }
            step.action()
            if step.record { framesLeft = Int((step.seconds * fps).rounded()) } else { stepEnds = Date().addingTimeInterval(step.seconds) }
        }

        nextStep()
        // Each tick captures what SwiftUI drew for the current clock, then moves the clock one frame on.
        // The interval leaves the run loop time to draw between ticks.
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard index < steps.count else { return }
                let step = steps[index]
                if !step.record {
                    if Date() >= stepEnds { nextStep() }
                    return
                }
                guard let image = capture() else { return }
                var alpha: CGFloat = 1
                if fadeLeft > 0 { alpha = 1 - CGFloat(fadeLeft) / CGFloat(fadeFrames + 1); fadeLeft -= 1 }
                writer.append(image, under: alpha < 1 ? fadeFrom : nil, alpha: alpha, background: background, at: Double(frame) / fps)
                previous = image
                frame += 1
                tour.clock += 1 / fps
                framesLeft -= 1
                if framesLeft <= 0 { nextStep() }
            }
        }
        app.run()
    }
}

/// Writes CGImages to an H.264 movie.
final class VideoWriter: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int

    init?(url: URL, width: Int, height: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        writer = w; self.width = width; self.height = height
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
    }

    /// Draws `image` (faded in over `under` when alpha < 1) onto an opaque background and appends it at `seconds`.
    func append(_ image: CGImage, under: CGImage?, alpha: CGFloat, background: CGColor, at seconds: Double) {
        // Not a live recording: wait for the encoder rather than drop a frame.
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        guard let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(background); ctx.fill(rect)
        ctx.interpolationQuality = .high
        if let under { ctx.draw(under, in: rect) }
        ctx.setAlpha(alpha)
        ctx.draw(image, in: rect)
        adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func finish(_ done: @escaping () -> Void) {
        input.markAsFinished()
        writer.finishWriting { DispatchQueue.main.async(execute: done) }
    }
}
