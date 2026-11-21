import AppKit
import ImageIO
import UniformTypeIdentifiers
import SweepCore

/// A made-up Mac for screenshots: a fake home and root folder in a temporary directory, filled with
/// invented apps, junk, projects and photos, plus canned answers for every external tool.
/// Nothing in it comes from the real Mac, and no real command ever runs while it is active.
enum Demo {
    /// Set before `AppState.shared` is first touched (see `--snapshot <dir> --demo`).
    nonisolated(unsafe) static var active: DemoMac?
}

final class DemoMac: @unchecked Sendable {
    let base: URL
    let env: SweepEnvironment
    let runner: DemoRunner
    var activityURL: URL { base.appendingPathComponent("state/activity.json") }
    var historyURL: URL { base.appendingPathComponent("state/battery-history.json") }
    var shredderQueue: [URL] = []
    private var blobs: [Int: URL] = [:]
    private let fm = FileManager.default
    private let now = Date()

    init() throws {
        base = fm.temporaryDirectory.appendingPathComponent("MyOpenCleanerDemo-\(UUID().uuidString)").resolvingSymlinksInPath()
        for dir in ["home", "root", "blobs", "state"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        env = SweepEnvironment(home: base.appendingPathComponent("home"), root: base.appendingPathComponent("root"))
        runner = DemoRunner(home: env.home.path)
        try seed()
    }

    func remove() { try? fm.removeItem(at: base) }

    // MARK: - Building blocks

    /// One real file per size; everything else is an APFS clone of it, so the demo Mac reports
    /// gigabytes while using only a few hundred megabytes of disk.
    private func blob(_ mb: Int) throws -> URL {
        if let b = blobs[mb] { return b }
        let url = base.appendingPathComponent("blobs/\(mb).bin")
        fm.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        var chunk = Data(count: 1_048_576)
        chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        for _ in 0..<mb { h.write(chunk) }
        try h.close()
        blobs[mb] = url
        return url
    }

    /// Places a file of `mb` megabytes. `unique` changes its first bytes so it is not a duplicate of the other clones.
    @discardableResult
    private func file(_ path: String, mb: Int, unique: Bool = true, daysOld: Double? = nil) throws -> URL {
        let url = env.resolve(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: try blob(mb), to: url)
        if unique {
            let h = try FileHandle(forWritingTo: url)
            var stamp = Data(count: 64)
            stamp.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            h.write(stamp)
            try h.close()
        }
        if let daysOld { age(url, daysOld) }
        return url
    }

    @discardableResult
    private func small(_ path: String, _ text: String = "demo", daysOld: Double? = nil) throws -> URL {
        let url = env.resolve(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let daysOld { age(url, daysOld) }
        return url
    }

    private func plist(_ path: String, _ dict: [String: Any]) throws {
        let url = env.resolve(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: url)
    }

    private func age(_ url: URL, _ days: Double) {
        let date = now.addingTimeInterval(-days * 86_400)
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        var t = [timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0),
                 timeval(tv_sec: Int(date.timeIntervalSince1970), tv_usec: 0)]
        utimes(url.path, &t)
    }

    private func app(_ path: String, id: String, name: String, version: String, color: NSColor, glyph: String,
                     mb: Int, feed: String? = nil, appStore: Bool = false) throws {
        var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version,
                                   "CFBundleVersion": "1", "CFBundleIconFile": "AppIcon", "CFBundlePackageType": "APPL",
                                   "CFBundleExecutable": name, "LSMinimumSystemVersion": "11.0"]
        if let feed { info["SUFeedURL"] = feed }
        try plist(path + "/Contents/Info.plist", info)
        let exe = env.resolve(path + "/Contents/MacOS/\(name)")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: exe)
        try file(path + "/Contents/Resources/Assets.car", mb: mb)
        try writeIcon(env.resolve(path + "/Contents/Resources/AppIcon.icns"), color: color, glyph: glyph)
        if appStore { try small(path + "/Contents/_MASReceipt/receipt") }
    }

    // MARK: - The fake Mac

    private func seed() throws {
        try seedApps()
        try seedJunk()
        try seedDeveloper()
        try seedFiles()
        try seedPhotos()
        try seedLaunchItems()
        try seedPrivacyAndCloud()
        try seedActivity()
    }

    private func seedApps() throws {
        try app("/Applications/PixelPaint.app", id: "com.example.PixelPaint", name: "PixelPaint", version: "3.2.1",
                color: .systemPink, glyph: "P", mb: 70, feed: "https://updates.example.com/pixelpaint/appcast.xml")
        try app("/Applications/Tasklet.app", id: "com.example.Tasklet", name: "Tasklet", version: "1.8",
                color: .systemOrange, glyph: "T", mb: 24, appStore: true)
        try app("/Applications/SoundBox.app", id: "com.example.SoundBox", name: "SoundBox", version: "5.0.2",
                color: .systemPurple, glyph: "S", mb: 130, feed: "https://updates.example.com/soundbox/appcast.xml")
        try app("/Applications/Streamer.app", id: "com.example.Streamer", name: "Streamer", version: "12.4",
                color: .systemGreen, glyph: "▶", mb: 70)
        try app("/Applications/Notekeeper.app", id: "com.example.Notekeeper", name: "Notekeeper", version: "2.0",
                color: .systemYellow, glyph: "N", mb: 9, appStore: true)
        try app("/Applications/Utilities/DiskPeek.app", id: "com.example.DiskPeek", name: "DiskPeek", version: "0.9",
                color: .systemTeal, glyph: "D", mb: 3)
        try app("~/Applications/Sketchbook.app", id: "com.example.Sketchbook", name: "Sketchbook", version: "4.1",
                color: .systemBlue, glyph: "✎", mb: 24)

        // What PixelPaint keeps in the Library (shown by the Uninstaller).
        try file("~/Library/Application Support/PixelPaint/Brushes.db", mb: 70)
        try file("~/Library/Application Support/PixelPaint/Plugins/filters.bundle", mb: 9)
        try small("~/Library/Preferences/com.example.PixelPaint.plist")
        try file("~/Library/Saved Application State/com.example.PixelPaint.savedState/window.data", mb: 1)
        try file("~/Library/HTTPStorages/com.example.PixelPaint/httpstorages.sqlite", mb: 1)
        try file("~/Library/Logs/PixelPaint/render.log", mb: 3)

        // Leftovers of apps that are gone.
        try file("~/Library/Application Support/com.oldvendor.PhotoTool/cache.db", mb: 24)
        try small("~/Library/Preferences/com.oldvendor.PhotoTool.plist")
        try plist("~/Library/Containers/7C1E2A4B-DEMO-4C11-9D2E-0A1B2C3D4E5F/.com.apple.containermanagerd.metadata.plist",
                  ["MCMMetadataIdentifier": "com.gone.MusicMaker"])
        try file("~/Library/Containers/7C1E2A4B-DEMO-4C11-9D2E-0A1B2C3D4E5F/Data/Library/samples.db", mb: 9)
        try file("~/Library/HTTPStorages/com.gone.MusicMaker/httpstorages.sqlite", mb: 1)
        try small("~/Library/Preferences/com.trialware.Converter.plist")
    }

    private func seedJunk() throws {
        try file("~/Library/Caches/com.example.SoundBox/AudioCache.db", mb: 130)
        try file("~/Library/Caches/com.example.Streamer/fsCachedData/blob", mb: 70)
        try file("~/Library/Caches/com.example.PixelPaint/thumbnails.db", mb: 24)
        try file("~/Library/Caches/com.example.Tasklet/Cache.db", mb: 9)
        try file("~/Library/Caches/com.example.Notekeeper/previews", mb: 3)
        try file("~/Library/Caches/com.apple.Safari/WebKitCache/Version 16/Records", mb: 70)
        try file("~/Library/Caches/Google/Chrome/Default/Cache/Cache_Data/data_1", mb: 130)
        try file("~/Library/Caches/Firefox/Profiles/a1b2c3.default/cache2/entries", mb: 24)
        try file("~/Library/Logs/DiagnosticReports/SoundBox-2024-11-02.ips", mb: 1)
        try file("~/Library/Logs/Streamer/streamer.log", mb: 9)
        try file("/Library/Caches/com.example.updater/payload.pkg", mb: 24)
        try file("/Library/Logs/DiagnosticReports/kernel-panic.ips", mb: 1)
        try file("/private/var/log/system.log.0.gz", mb: 3)
        try file("/private/var/log/install.log.1.gz", mb: 9)
        try file("~/Library/Caches/Homebrew/downloads/node--22.11.0.bottle.tar.gz", mb: 70)
        try file("~/Library/Caches/pip/http/wheels.bin", mb: 24)
        try file("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/1A2B/Invoice-0423.pdf", mb: 3, daysOld: 90)
        try file("~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/3C4D/Brochure.pdf", mb: 9, daysOld: 120)
        try file("~/.Trash/old-website.zip", mb: 70)
        try file("~/.Trash/Screen Recording.mov", mb: 130)
        try file("~/Library/Application Support/MobileSync/Backup/00008110-DEMO0000DEMO/Manifest.db", mb: 180)
        try file("~/Downloads/Sketchbook-4.1.dmg", mb: 70, daysOld: 30)
        try file("~/Downloads/SoundBox-Installer.pkg", mb: 24, daysOld: 60)
        try file("~/Downloads/conference-talk.mp4.crdownload", mb: 9, daysOld: 3)
    }

    private func seedDeveloper() throws {
        try file("~/Library/Developer/Xcode/DerivedData/ShopApp-fqzlwbmhcxdsat/Build/Intermediates.noindex/x", mb: 180)
        try file("~/Library/Developer/Xcode/DerivedData/WeatherKit-ajkdhwueqnbzpx/Build/Products/x", mb: 70)
        try file("~/Library/Developer/Xcode/DerivedData/Notes-bhgtwzsnqkdmrl/Index.noindex/x", mb: 24)
        try file("~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 18.2 (22C152)/Symbols/x", mb: 180)
        try file("~/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.5 (21F90)/Symbols/x", mb: 130, daysOld: 200)
        try file("~/Library/Developer/Xcode/Archives/2024-03-12/ShopApp 1.0.xcarchive/Products/x", mb: 70, daysOld: 250)
        try file("~/Library/Developer/CoreSimulator/Caches/dyld/x", mb: 24)
        try file("~/Library/iTunes/iPhone Software Updates/iPhone17,1_18.2_22C152_Restore.ipsw", mb: 180, daysOld: 40)
        try file("~/.npm/_cacache/content-v2/sha512/x", mb: 130)
        try file("~/.npm/_npx/9a8b7c/node_modules/x", mb: 24)
        try file("~/Library/Caches/Yarn/v6/x", mb: 70)
        try file("~/.gradle/caches/modules-2/x", mb: 130)
        try file("~/.cargo/registry/cache/index/x", mb: 24)
        try file("~/.android/avd/Pixel_8_API_35.avd/userdata-qemu.img", mb: 180)
        try small("~/.android/avd/Pixel_8_API_35.ini")
        try file("~/Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img", mb: 130)

        func project(_ dir: String, marker: String, artifact: String, payload: String, mb: Int, daysOld: Double) throws {
            try small("~/Code/\(dir)/\(marker)", daysOld: daysOld)
            try small("~/Code/\(dir)/README.md", daysOld: daysOld)
            try file("~/Code/\(dir)/\(artifact)/\(payload)", mb: mb)
        }
        try project("web-shop", marker: "package.json", artifact: "node_modules",
                    payload: "@next/swc-darwin-arm64/next-swc.darwin-arm64.node", mb: 180, daysOld: 2)
        try file("~/Code/web-shop/.next/cache/x", mb: 24)
        try project("landing-page", marker: "package.json", artifact: "node_modules", payload: "esbuild/bin/esbuild", mb: 70, daysOld: 95)
        try project("ios-weather", marker: "Package.swift", artifact: ".build", payload: "debug/WeatherKit.swiftmodule", mb: 130, daysOld: 12)
        try project("rust-cli", marker: "Cargo.toml", artifact: "target", payload: "release/deps/librust_cli.rlib", mb: 180, daysOld: 140)
        try small("~/Code/android-notes/settings.gradle", daysOld: 60)
        try small("~/Code/android-notes/app/build.gradle", daysOld: 60)
        try file("~/Code/android-notes/app/build/outputs/apk/app.apk", mb: 70)
        try project("ios-shop", marker: "Podfile", artifact: "Pods", payload: "Firebase/FirebaseCore.xcframework", mb: 24, daysOld: 33)
    }

    private func seedFiles() throws {
        try file("~/Movies/Family Reunion 2023.mov", mb: 180, daysOld: 420)
        try file("~/Movies/Drone Footage/coastline-4k.mp4", mb: 130, daysOld: 200)
        try file("~/Music/Live Session.wav", mb: 130, daysOld: 500)
        try file("~/Documents/Archive/Photos 2019.zip", mb: 180, daysOld: 700)
        try file("~/Documents/VMs/Ubuntu.qcow2", mb: 130, daysOld: 30)
        // True duplicates (no unique stamp): the same bytes in two places.
        try file("~/Downloads/Linux-Desktop-24.04.iso", mb: 130, unique: false, daysOld: 20)
        try file("~/Documents/ISO/Linux-Desktop-24.04 copy.iso", mb: 130, unique: false, daysOld: 10)
        try file("~/Desktop/Mockup.psd", mb: 24, unique: false)
        try file("~/Documents/Design/Mockup (final).psd", mb: 24, unique: false)
        try file("~/Downloads/Quarterly Report.pdf", mb: 3, unique: false)
        try file("~/Documents/Work/Quarterly Report (1).pdf", mb: 3, unique: false)
        try file("~/Documents/Work/Old/Quarterly Report copy.pdf", mb: 3, unique: false)
        try file("~/Downloads/Pitch Deck.key", mb: 9, unique: false)
        try file("~/Documents/Pitch Deck.key", mb: 9, unique: false)
        try small("~/Documents/Notes/todo.txt", "buy milk")

        shredderQueue = [
            try file("~/Documents/Tax Return 2022.pdf", mb: 3),
            try file("~/Desktop/Old Contracts/contract-signed.pdf", mb: 1).deletingLastPathComponent(),
            try file("~/Downloads/bank-statement-march.pdf", mb: 1),
        ]
    }

    private func seedLaunchItems() throws {
        func agent(_ folder: String, _ label: String, program: String, createProgram: Bool = true,
                   runAtLoad: Bool = true, keepAlive: Bool = false) throws {
            try plist("\(folder)/\(label).plist", ["Label": label, "ProgramArguments": [program],
                                                  "RunAtLoad": runAtLoad, "KeepAlive": keepAlive])
            if createProgram { try file(program, mb: 1) }
        }
        try agent("~/Library/LaunchAgents", "com.example.PixelPaint.helper",
                  program: "/Applications/PixelPaint.app/Contents/Library/LoginItems/Helper", createProgram: false)
        try file("/Applications/PixelPaint.app/Contents/Library/LoginItems/Helper", mb: 1)
        try agent("~/Library/LaunchAgents", "com.example.Streamer.updater", program: "/Library/Application Support/Streamer/updater")
        try agent("~/Library/LaunchAgents", "com.genieo.engine", program: "/Library/Application Support/Genieo/engine")
        try agent("~/Library/LaunchAgents", "com.updater.xkqzvbnmtr", program: "/private/tmp/.cache/run", keepAlive: true)
        try agent("~/Library/LaunchAgents", "com.example.OldSync.agent", program: "/Applications/OldSync.app/Contents/MacOS/agent",
                  createProgram: false)
        try agent("/Library/LaunchAgents", "com.example.SoundBox.audiohelper", program: "/Library/Application Support/SoundBox/audiohelper")
        try agent("/Library/LaunchDaemons", "com.example.vpn.helper", program: "/Library/PrivilegedHelperTools/com.example.vpn.helper",
                  keepAlive: true)
        try agent("/Library/LaunchDaemons", "com.example.backup.scheduler", program: "/Library/Application Support/Backup/scheduler",
                  runAtLoad: false)
    }

    private func seedPrivacyAndCloud() throws {
        try file("~/Library/Safari/History.db", mb: 9)
        try small("~/Library/Safari/Downloads.plist")
        try file("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies", mb: 1)
        try file("~/Library/Application Support/Google/Chrome/Default/History", mb: 24)
        try file("~/Library/Application Support/Google/Chrome/Default/Cookies", mb: 3)
        try file("~/Library/Application Support/Google/Chrome/Default/Web Data", mb: 3)
        try file("~/Library/Application Support/Google/Chrome/Default/Login Data", mb: 1)   // never offered
        try file("~/Library/Application Support/Firefox/Profiles/a1b2c3.default/places.sqlite", mb: 9)
        try file("~/Library/Application Support/Firefox/Profiles/a1b2c3.default/cookies.sqlite", mb: 1)
        try small("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl3")

        try file("~/Library/Mobile Documents/com~apple~CloudDocs/Videos/Wedding Highlights.mov", mb: 180)
        try file("~/Library/Mobile Documents/com~apple~CloudDocs/Design/Brand Assets.zip", mb: 70)
        try file("~/Library/Mobile Documents/com~apple~CloudDocs/Scans/Receipts 2023.pdf", mb: 24)
        try file("~/Library/CloudStorage/GoogleDrive-Personal/My Drive/Backups/site-backup.tar.gz", mb: 130)
        try file("~/Library/CloudStorage/Dropbox/Shared Projects/footage-raw.mp4", mb: 70)
        try file("~/Library/CloudStorage/OneDrive-Personal/Documents/Annual Report.pptx", mb: 24)
    }

    private func seedActivity() throws {
        let log = ActivityLog(fileURL: activityURL)
        for (days, module, mb, n) in [(28.0, "System Junk", 4_200, 312), (21, "Developer", 18_600, 9), (14, "Duplicates", 2_100, 14),
                                      (9, "Uninstaller", 1_300, 7), (3, "Quick Scan", 3_800, 205), (1, "Shredder", 12, 2)] {
            log.record(module: module, freed: Int64(mb) * 1_048_576, items: n, at: now.addingTimeInterval(-days * 86_400))
        }
        log.markMaintenance(["flush-dns", "rebuild-launch-services"], at: now.addingTimeInterval(-12 * 86_400))
        log.markMaintenance(["free-ram"], at: now.addingTimeInterval(-3_600))
    }

    // MARK: - Photos

    /// Landscapes drawn from a seed. Shots of the same scene shifted slightly or resized are "similar".
    private func seedPhotos() throws {
        let scenes: [(seed: Int, shots: [(dx: CGFloat, scale: CGFloat)])] = [
            (1, [(0, 1), (6, 1), (12, 1), (0, 0.5)]),
            (2, [(0, 1), (-8, 1), (0, 0.6)]),
            (3, [(0, 1), (5, 1)]),
            (4, [(0, 1)]), (5, [(0, 1)]), (6, [(0, 1)]),
        ]
        var n = 4810
        for scene in scenes {
            for shot in scene.shots {
                n += 1
                let folder = scene.seed <= 3 ? "~/Pictures/Iceland Trip" : "~/Pictures/Misc"
                let size = CGSize(width: 1600 * shot.scale, height: 1067 * shot.scale)
                try writeJPEG(landscape(seed: scene.seed, size: size, dx: shot.dx * shot.scale),
                              to: env.resolve("\(folder)/IMG_\(n).jpg"))
            }
        }
    }

    private func landscape(seed: Int, size: CGSize, dx: CGFloat) -> CGImage {
        let palettes: [[NSColor]] = [
            [.systemOrange, .systemPink, .systemIndigo], [.systemTeal, .systemBlue, .black],
            [.systemYellow, .systemOrange, .brown], [.systemMint, .systemCyan, .systemBlue],
            [.systemPurple, .systemPink, .systemRed], [.white, .systemGray, .darkGray],
        ]
        let p = palettes[(seed - 1) % palettes.count]
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = size.width, h = size.height
        // Sky: vertical for even seeds, diagonal for odd ones, so different scenes hash differently.
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [p[0].cgColor, p[1].cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: seed % 2 == 0 ? 0 : w, y: h),
                               end: CGPoint(x: seed % 2 == 0 ? 0 : 0, y: 0), options: [])
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        let sunX = w * CGFloat((seed * 37) % 80 + 10) / 100 + dx
        ctx.fillEllipse(in: CGRect(x: sunX, y: h * 0.62, width: h * 0.16, height: h * 0.16))
        // Mountains: peak positions depend on the seed.
        let ridges: [[CGFloat]] = [
            [0.30, 0.62, 0.35, 0.70, 0.40, 0.58, 0.30, 0.50, 0.35],
            [0.72, 0.45, 0.20, 0.18, 0.30, 0.55, 0.78, 0.60, 0.40],
            [0.10, 0.15, 0.25, 0.55, 0.85, 0.55, 0.25, 0.15, 0.10],
            [0.50, 0.50, 0.20, 0.20, 0.50, 0.50, 0.20, 0.20, 0.50],
            [0.15, 0.30, 0.45, 0.60, 0.75, 0.60, 0.45, 0.30, 0.15],
            [0.80, 0.20, 0.80, 0.20, 0.80, 0.20, 0.80, 0.20, 0.80],
        ]
        let ridge = ridges[(seed - 1) % ridges.count]
        ctx.setFillColor(p[2].cgColor)
        ctx.move(to: CGPoint(x: 0, y: 0))
        for (i, r) in ridge.enumerated() {
            ctx.addLine(to: CGPoint(x: w * CGFloat(i) / 8 + dx, y: h * r))
        }
        ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.fillPath()
        return ctx.makeImage()!
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func writeIcon(_ url: URL, color: NSColor, glyph: String) throws {
        let px = 512
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rect = NSRect(x: 50, y: 50, width: 412, height: 412)
        NSGradient(colors: [color.blended(withFraction: 0.35, of: .white)!, color])!
            .draw(in: NSBezierPath(roundedRect: rect, xRadius: 92, yRadius: 92), angle: -90)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 230, weight: .bold),
                                                    .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: glyph, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Battery and system figures

    var battery: BatteryInfo? {
        let top: [String: Any] = [
            "MaxCapacity": 100, "CurrentCapacity": 76, "AppleRawMaxCapacity": 6_412, "AppleRawCurrentCapacity": 4_873,
            "DesignCapacity": 6_249, "NominalChargeCapacity": 6_105, "CycleCount": 187, "DesignCycleCount9C": 1_000,
            "Temperature": 3_120, "Voltage": 12_610, "InstantAmperage": 3_240, "IsCharging": true, "ExternalConnected": true,
            "AvgTimeToFull": 52, "Serial": "DEMO000000000000", "DeviceName": "demo-gauge",
            "AdapterDetails": ["Watts": 96, "Name": "96W USB-C Power Adapter", "AdapterVoltage": 20_000, "Current": 4_800],
            "PowerTelemetryData": ["SystemLoad": 14_200, "SystemPowerIn": 55_300],
            "BatteryData": ["ManufactureDate": (2023 - 1980) << 9 | 2 << 5 | 14,
                            "LifetimeData": ["MaximumTemperature": 452, "MinimumTemperature": 118, "TotalOperatingTime": 11_400]],
        ]
        return BatteryInfo(top: top, pack: nil, banks: [])
    }

    let system = MacSystemInfo(computerName: "Demo Mac", modelID: "MacBookPro99,1", marketingName: "MacBook Pro (16-inch, Nov 2023)",
                               chip: "Apple M3 Max", serial: nil, osVersion: "macOS 15.1")
}

/// Canned answers for every tool the app calls. It never starts a process.
struct DemoRunner: CommandRunning {
    let home: String

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let cmd = ([executable] + arguments).joined(separator: " ")
        func ok(_ s: String) -> CommandResult { CommandResult(status: 0, output: s) }
        if cmd.hasPrefix("/usr/bin/xcrun simctl list devices") { return ok(devices) }
        if cmd.hasPrefix("/usr/bin/xcrun simctl runtime list") { return ok(runtimes) }
        if cmd.hasPrefix("/usr/local/bin/docker system df") { return ok(dockerDF) }
        if cmd.hasPrefix("/usr/sbin/networksetup -listpreferredwirelessnetworks") {
            return ok("Preferred networks on en0:\n\tHome Network\n\tOffice Wi-Fi\n\tCoffee Shop Guest\n\tAirport Free Wi-Fi\n")
        }
        if cmd.hasPrefix("/bin/ps") { return ok(processes) }
        return ok("")
    }

    private func device(_ udid: String, _ name: String, gb: Double, lastUsedDays: Int?, available: Bool = true) -> String {
        let used = lastUsedDays.map { #", "lastUsedAt": "\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double($0) * 86_400)))""# } ?? ""
        return #"{"udid": "\#(udid)", "name": "\#(name)", "state": "Shutdown", "isAvailable": \#(available), "dataPathSize": \#(Int64(gb * 1e9)), "dataPath": "\#(home)/Library/Developer/CoreSimulator/Devices/\#(udid)/data"\#(used)}"#
    }

    private var devices: String {
        """
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
            \(device("A0000000-0000-4000-8000-000000000001", "iPhone 16 Pro", gb: 6.4, lastUsedDays: 1)),
            \(device("A0000000-0000-4000-8000-000000000002", "iPhone 16", gb: 4.1, lastUsedDays: 9)),
            \(device("A0000000-0000-4000-8000-000000000003", "iPad Air 13-inch (M2)", gb: 2.7, lastUsedDays: 140))
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
            \(device("A0000000-0000-4000-8000-000000000004", "iPhone 15", gb: 3.2, lastUsedDays: 210)),
            \(device("A0000000-0000-4000-8000-000000000005", "iPhone SE (3rd generation)", gb: 1.4, lastUsedDays: nil))
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
            \(device("A0000000-0000-4000-8000-000000000006", "iPhone 14 Pro", gb: 2.2, lastUsedDays: 400, available: false))
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-2": [
            \(device("A0000000-0000-4000-8000-000000000007", "Apple Watch Series 10 (46mm)", gb: 1.1, lastUsedDays: 60))
          ]
        }}
        """
    }

    private var runtimes: String {
        func r(_ id: String, _ rt: String, _ ver: String, _ build: String, gb: Double, usedDays: Int?) -> String {
            let used = usedDays.map { #", "lastUsedAt": "\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double($0) * 86_400)))""# } ?? ""
            return #""\#(id)": {"identifier": "\#(id)", "version": "\#(ver)", "build": "\#(build)", "sizeBytes": \#(Int64(gb * 1e9)), "deletable": true, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.\#(rt)"\#(used)}"#
        }
        return "{" + [
            r("B0000000-0000-4000-8000-000000000001", "iOS-18-2", "18.2", "22C150", gb: 8.4, usedDays: 1),
            r("B0000000-0000-4000-8000-000000000002", "iOS-17-5", "17.5", "21F79", gb: 7.3, usedDays: 210),
            r("B0000000-0000-4000-8000-000000000003", "iOS-16-4", "16.4", "20E247", gb: 6.6, usedDays: nil),
            r("B0000000-0000-4000-8000-000000000004", "watchOS-11-2", "11.2", "22S99", gb: 4.0, usedDays: 60),
        ].joined(separator: ",") + "}"
    }

    private let dockerDF = """
    {"Active":"3","Reclaimable":"6.8GB (58%)","Size":"11.7GB","TotalCount":"14","Type":"Images"}
    {"Active":"3","Reclaimable":"420MB (71%)","Size":"590MB","TotalCount":"9","Type":"Containers"}
    {"Active":"2","Reclaimable":"1.3GB (44%)","Size":"2.9GB","TotalCount":"6","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"5.2GB","Size":"5.2GB","TotalCount":"212","Type":"Build Cache"}
    """

    private let processes = """
    412 38.5 1843200 Xcode
    518 21.0 942080 Google Chrome Helper (Renderer)
    151 12.4 286720 WindowServer
    903 8.1 1228800 Simulator
    677 5.6 655360 SoundBox
    740 3.2 512000 Streamer
    233 2.0 131072 Finder
    880 1.4 409600 PixelPaint
    """
}

extension DemoMac {
    /// Fixed figures for the Mac Health page and the menu bar.
    var memory: MemoryStats {
        let gb: UInt64 = 1 << 30
        return MemoryStats(total: 36 * gb, free: 6 * gb, active: 14 * gb, inactive: 6 * gb, wired: 4 * gb,
                           compressed: 3 * gb, purgeable: 1 * gb, external: 2 * gb)
    }
    var disk: DiskStats { DiskStats(total: 994_662_584_320, available: 312_480_000_000) }
    var cpuHistory: [Double] {
        (0..<60).map { (i: Int) -> Double in
            let t = Double(i)
            let slow: Double = 0.14 * sin(t / 5)
            let fast: Double = 0.05 * sin(t * 1.7)
            return 0.22 + slow + fast
        }
    }
}
