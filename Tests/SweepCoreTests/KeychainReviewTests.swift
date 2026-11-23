import Foundation
import Testing
@testable import SweepCore

/// Keychain entries of removed apps: read by name only, never deleted.
@Suite struct KeychainReviewTests {
    let dump = """
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        0x00000007 <blob>="com.gone.App"
        0x00000008 <blob>=<NULL>
        "acct"<blob>="me@example.com"
        "cdat"<timedate>=0x32303233303130313030303030305A00  "20230101000000Z\\000"
        "mdat"<timedate>=0x32303234303331353130303030305A00  "20240315100000Z\\000"
        "svce"<blob>="com.gone.App"
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>=0x6E6F7465  "note"
        "svce"<blob>=0x636F6D2E6578616D706C652E4E6F74652E68656C706572  "com.example.Note.helper"
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "inet"
    attributes:
        "acct"<blob>="web"
        "srvr"<blob>="com.gone.website"
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="t"
        "svce"<blob>="com.apple.gs.idms.token"
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: "genp"
    attributes:
        "acct"<blob>="cli"
        "svce"<blob>="gh:github.com"
    keychain: "/Users/x/Library/Keychains/login.keychain-db"
    version: 512
    class: 0x0000000F
    attributes:
        0x00000001 <blob>="a key"
    """

    @Test func parsesPasswordsOnly() {
        let entries = KeychainReview.parse(dump)
        #expect(entries.map(\.service) == ["com.gone.App", "com.example.Note.helper", "com.apple.gs.idms.token", "gh:github.com"],
                "internet passwords and keys are left out")
        let gone = entries[0]
        #expect(gone.account == "me@example.com" && gone.label == "com.gone.App")
        #expect(gone.modified == ISO8601DateFormatter().date(from: "2024-03-15T10:00:00Z"))
        #expect(entries[1].account == "note", "hex values are decoded")
    }

    @Test func onlyEntriesOfRemovedAppsAreListed() {
        let stale = KeychainReview.stale(KeychainReview.parse(dump), installed: ["com.example.Note"])
        #expect(stale.map(\.service) == ["com.gone.App"],
                "Apple's entries, helpers of installed apps and CLI tools (not bundle IDs) are never listed")
    }

    @Test func relatedNamesOfInstalledAppsAreKept() {
        let entries = ["com.vendor", "com.vendor.App", "com.vendor.App.sync", "COM.Vendor.app", "com.other.Thing"]
            .map { KeychainEntry(service: $0, account: "") }
        let stale = KeychainReview.stale(entries, installed: ["com.vendor.app"])
        #expect(stale.map(\.service) == ["com.other.Thing"])
    }

    @Test func bundleIDShape() {
        #expect(KeychainReview.looksLikeBundleID("com.example.App"))
        #expect(KeychainReview.looksLikeBundleID("io.github.some-tool.cli"))
        for s in ["example.App", "gh:github.com", "My App.com.x", "com..x", "AirPort", ""] {
            #expect(!KeychainReview.looksLikeBundleID(s), "\(s)")
        }
    }

    @Test func readsWithoutSecretsAndNeverDeletes() {
        let runner = FakeRunner()
        runner.responses["/usr/bin/security dump-keychain"] = CommandResult(status: 0, output: dump)
        let stale = KeychainReview(runner: runner).staleEntries(installed: [])
        #expect(stale.map(\.service) == ["com.example.Note.helper", "com.gone.App"])
        #expect(runner.calls == [["/usr/bin/security", "dump-keychain"]], "no -d (secrets), no delete-* command")
    }

    @Test func aFailedDumpListsNothing() {
        let runner = FakeRunner()
        runner.defaultResult = CommandResult(status: 1, error: "denied")
        #expect(KeychainReview(runner: runner).staleEntries(installed: []).isEmpty)
    }
}
