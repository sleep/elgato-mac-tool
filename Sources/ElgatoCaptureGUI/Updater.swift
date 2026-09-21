import AppKit
import CryptoKit
import SwiftUI

/// Self-update from GitHub Releases: asks the API for the latest release, and if its
/// tag is newer than this bundle's version, downloads the DMG, stages the app inside
/// it next to the running bundle and hands over to a tiny shell script that swaps the
/// two once we've quit, then relaunches.
///
/// Only active in the packaged .app — an unbundled `swift run` build has no version
/// and nothing to replace. All network / disk work happens off the main actor.
@MainActor
final class Updater: ObservableObject {

    enum Phase: Equatable {
        case idle, checking, downloading, installing
    }

    @Published private(set) var phase: Phase = .idle

    static let repo = "sleep/elgato-mac-tool"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let settings: AppSettings
    /// Installing relaunches the app, so it must never happen mid-recording.
    private let isRecording: () -> Bool
    private var progressWindow: NSWindow?

    init(settings: AppSettings, isRecording: @escaping () -> Bool) {
        self.settings = settings
        self.isRecording = isRecording
    }

    /// Version of the running bundle, or nil when not running from a packaged .app.
    var currentVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var isAvailable: Bool { currentVersion != nil }

    // MARK: - Checking

    /// Launch-time check: at most once a day, silent unless there's something to install.
    func checkInBackgroundIfDue() {
        guard isAvailable, settings.checkForUpdatesAutomatically else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < Self.checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard phase == .idle, let currentVersion else { return }
        // A modal alert stealing focus mid-recording is worse than a late update;
        // leave lastUpdateCheck alone so the next launch tries again.
        if !userInitiated && isRecording() { return }

        phase = .checking
        defer { if phase == .checking { phase = .idle } }

        do {
            let release = try await Self.fetchLatestRelease()
            settings.lastUpdateCheck = Date()

            guard AppVersion(release.version) > AppVersion(currentVersion) else {
                if userInitiated {
                    showMessage("You're up to date",
                                "Elgato Capture \(currentVersion) is the latest version.")
                }
                return
            }
            if !userInitiated && settings.skippedUpdateVersion == release.version { return }
            phase = .idle
            offer(release, currentVersion: currentVersion)
        } catch {
            print("[Updater] Check failed: \(error)")
            if userInitiated {
                showMessage("Couldn't check for updates", error.localizedDescription, style: .warning)
            }
        }
    }

    private func offer(_ release: Release, currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "Elgato Capture \(release.version) is available"
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = "You have \(currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await install(release) }
        case .alertThirdButtonReturn:
            settings.skippedUpdateVersion = release.version
        default:
            break
        }
    }

    // MARK: - Installing

    private func install(_ release: Release) async {
        guard phase == .idle, let currentVersion else { return }
        guard !isRecording() else {
            showMessage("Recording in progress",
                        "Stop the recording first — installing the update relaunches the app.",
                        style: .warning)
            return
        }

        let bundleURL = Bundle.main.bundleURL
        showProgressWindow()
        defer { closeProgressWindow() }

        do {
            try Self.checkReplaceable(bundleURL)
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                throw UpdateError.noInstaller
            }

            phase = .downloading
            let dmg = try await Self.download(asset)

            phase = .installing
            let staged = try await Self.stage(dmg: dmg, replacing: bundleURL,
                                              newerThan: currentVersion)

            // Re-check: the download took a while and recording may have started since.
            guard !isRecording() else {
                try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
                throw UpdateError.recordingStarted
            }
            try Self.launchSwapScript(staged: staged, target: bundleURL)
            NSApp.terminate(nil)
        } catch {
            print("[Updater] Install failed: \(error)")
            phase = .idle
            closeProgressWindow()
            showMessage("Update failed", error.localizedDescription, style: .warning)
        }
    }

    /// The swap is a rename in the bundle's parent directory, so that has to be ours
    /// to write — and the bundle has to be at its real path, not a translocated copy.
    private nonisolated static func checkReplaceable(_ bundleURL: URL) throws {
        if bundleURL.path.contains("/AppTranslocation/") {
            throw UpdateError.translocated
        }
        let parent = bundleURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError.notWritable(parent)
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private nonisolated static func download(_ asset: Release.Asset) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // URLSession deletes its temp file when we return; keep our own copy.
        let dmg = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElgatoCaptureUpdate-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)

        // GitHub publishes a digest per asset; older releases may not have one.
        if let expected = asset.digest, expected.hasPrefix("sha256:") {
            let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard "sha256:\(actual)" == expected.lowercased() else {
                try? FileManager.default.removeItem(at: dmg)
                throw UpdateError.checksumMismatch
            }
        }
        return dmg
    }

    /// Mount the DMG, copy its .app into a staging directory on the same volume as the
    /// running bundle (so the later swap is an atomic rename) and make sure it's really
    /// a newer, intact build of this app before we let it replace anything.
    private nonisolated static func stage(dmg: URL, replacing bundleURL: URL,
                                          newerThan currentVersion: String) async throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: dmg) }

        let mountPoint = fm.temporaryDirectory.appendingPathComponent("ElgatoCaptureUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                     "-mountpoint", mountPoint.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fm.removeItem(at: mountPoint)
        }

        guard let source = try fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInInstaller
        }

        let stagingDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: bundleURL, create: true)
        let staged = stagingDir.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            try run("/usr/bin/ditto", [source.path, staged.path])
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

            guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let version = info["CFBundleShortVersionString"] as? String,
                  AppVersion(version) > AppVersion(currentVersion) else {
                throw UpdateError.unexpectedApp
            }
            // Catches a truncated or tampered bundle: the seal covers every file in it.
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            try? fm.removeItem(at: stagingDir)
            throw error
        }
        return staged
    }

    /// We can't replace our own bundle while running, so a detached shell waits for this
    /// process to exit, swaps the bundles (restoring the old one if the move fails) and
    /// relaunches. Paths go in as positional arguments so they never need quoting.
    private nonisolated static func launchSwapScript(staged: URL, target: URL) throws {
        let script = """
        pid="$1"; staged="$2"; target="$3"; backup="$target.old-$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$target" "$backup"; then
            if mv "$staged" "$target"; then rm -rf "$backup"; else mv "$backup" "$target"; fi
        fi
        rm -rf "$(dirname "$staged")"
        open "$target"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh",
                             String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed((tool as NSString).lastPathComponent,
                                         output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    // MARK: - UI

    private func showMessage(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showProgressWindow() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: UpdateProgressView(updater: self))
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }
}

// MARK: - Progress view

private struct UpdateProgressView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(updater.phase == .downloading ? "Downloading update…" : "Installing update…")
            ProgressView().progressViewStyle(.linear)
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - Model

private struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let assets: [Asset]

    /// "v0.1.1" → "0.1.1"
    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    enum CodingKeys: String, CodingKey {
        case body, assets
        case tagName = "tag_name"
    }
}

/// Dotted numeric version, compared component-wise ("0.1.10" > "0.1.9", "0.1" == "0.1.0").
struct AppVersion: Comparable {
    private let parts: [Int]

    init(_ string: String) {
        // Ignore any pre-release / build suffix: "1.2.0-beta" → [1, 2, 0]
        let core = string.prefix { $0.isNumber || $0 == "." }
        parts = core.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func padded(to count: Int) -> [Int] {
        parts + Array(repeating: 0, count: max(0, count - parts.count))
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(to: n) == rhs.padded(to: n)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.parts.count, rhs.parts.count)
        return lhs.padded(to: n).lexicographicallyPrecedes(rhs.padded(to: n))
    }
}

private enum UpdateError: LocalizedError {
    case badResponse(Int)
    case noInstaller
    case noAppInInstaller
    case checksumMismatch
    case unexpectedApp
    case translocated
    case notWritable(String)
    case recordingStarted
    case toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "GitHub returned an unexpected response (HTTP \(code))."
        case .noInstaller:
            return "The latest release has no .dmg installer attached."
        case .noAppInInstaller:
            return "The downloaded installer doesn't contain an app."
        case .checksumMismatch:
            return "The download doesn't match the checksum published with the release."
        case .unexpectedApp:
            return "The downloaded app isn't a newer version of Elgato Capture."
        case .translocated:
            return "macOS is running the app from a temporary read-only location. Move Elgato Capture into Applications, relaunch it, then update."
        case .notWritable(let path):
            return "You don't have permission to replace the app in \(path). Download the new version from GitHub instead."
        case .recordingStarted:
            return "A recording started while the update was downloading. Try again once it's finished."
        case .toolFailed(let tool, let output):
            return "\(tool) failed" + (output.isEmpty ? "." : ": \(output)")
        }
    }
}
