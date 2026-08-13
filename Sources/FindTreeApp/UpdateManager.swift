import AppKit
import Combine
import CryptoKit
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    private enum State {
        case idle
        case checking
        case upToDate
        case available(Release)
        case updating
        case failed(String)
    }

    private struct Release: Sendable {
        let version: String
        let dmgURL: URL
        let checksumURL: URL
    }

    private struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable, Sendable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    private struct CommandResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    @Published private var state: State = .idle

    nonisolated private static let repositoryOwner = "walkingwifi28"
    nonisolated private static let repositoryName = "findtree"
    nonisolated private static let caskName = "findtree"

    var buttonTitle: String {
        switch state {
        case .idle, .upToDate, .failed:
            return "Check for updates"
        case .checking:
            return "Checking..."
        case .available(let release):
            return "Update Now (v\(release.version))"
        case .updating:
            return "Updating..."
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .updating:
            return true
        default:
            return false
        }
    }

    var statusMessage: String? {
        switch state {
        case .upToDate:
            return "You're up to date."
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    func performPrimaryAction() {
        switch state {
        case .available(let release):
            install(release)
        case .checking, .updating:
            break
        default:
            checkForUpdates()
        }
    }

    func checkForUpdates() {
        state = .checking

        Task {
            do {
                let release = try await Self.fetchLatestRelease()
                let currentVersion = Self.currentVersion

                if Self.compareVersions(release.version, currentVersion) == .orderedDescending {
                    state = .available(release)
                } else {
                    state = .upToDate
                }
            } catch {
                state = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    private func install(_ release: Release) {
        state = .updating

        Task {
            do {
                if try await Self.isManagedByHomebrew() {
                    try await Self.updateWithHomebrew(expectedVersion: release.version)
                    try Self.scheduleRelaunchAfterTermination()
                    NSApp.terminate(nil)
                    return
                }

                let preparedUpdate = try await Self.prepareDMGUpdate(release)
                try Self.scheduleDMGInstallAfterTermination(preparedUpdate)
                NSApp.terminate(nil)
            } catch {
                state = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    private struct PreparedDMGUpdate: Sendable {
        let temporaryDirectory: URL
        let mountPoint: URL
        let sourceApp: URL
        let targetApp: URL
    }

    nonisolated private static var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "0.0.0"
    }

    nonisolated private static func fetchLatestRelease() async throws -> Release {
        let endpoint = URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FindTree-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.releaseLookupFailed
        }

        let githubRelease = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = String(githubRelease.tagName.trimmingPrefix("v"))
        let expectedDMGName = "FindTree-\(version)-arm64.dmg"
        let expectedChecksumName = "\(expectedDMGName).sha256"

        guard let dmgURL = githubRelease.assets.first(where: { $0.name == expectedDMGName })?.downloadURL,
              let checksumURL = githubRelease.assets.first(where: { $0.name == expectedChecksumName })?.downloadURL else {
            throw UpdateError.releaseAssetMissing
        }

        return Release(version: version, dmgURL: dmgURL, checksumURL: checksumURL)
    }

    nonisolated private static func isManagedByHomebrew() async throws -> Bool {
        guard targetApplicationURL().path == "/Applications/FindTree.app",
              let brew = homebrewExecutable() else {
            return false
        }

        return try await Task.detached(priority: .utility) {
            let result = try runCommand(
                executable: brew,
                arguments: ["list", "--cask", "--versions", caskName]
            )
            return result.status == 0
        }.value
    }

    nonisolated private static func updateWithHomebrew(expectedVersion: String) async throws {
        guard let brew = homebrewExecutable() else {
            throw UpdateError.homebrewUnavailable
        }

        try await Task.detached(priority: .userInitiated) {
            let updateResult = try runCommand(executable: brew, arguments: ["update", "--quiet"])
            guard updateResult.status == 0 else {
                throw UpdateError.commandFailed(commandErrorMessage(updateResult))
            }

            let upgradeResult = try runCommand(
                executable: brew,
                arguments: ["upgrade", "--cask", "--no-quit", caskName]
            )
            guard upgradeResult.status == 0 else {
                throw UpdateError.commandFailed(commandErrorMessage(upgradeResult))
            }

            let installedVersion = installedAppVersion(at: targetApplicationURL())
            guard installedVersion == expectedVersion else {
                throw UpdateError.versionMismatch(expected: expectedVersion, actual: installedVersion)
            }
        }.value
    }

    nonisolated private static func prepareDMGUpdate(_ release: Release) async throws -> PreparedDMGUpdate {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("findtree-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        do {
            let dmgDestination = temporaryDirectory.appendingPathComponent("FindTree-\(release.version)-arm64.dmg")

            let (downloadedDMG, dmgResponse) = try await URLSession.shared.download(from: release.dmgURL)
            try validateHTTPResponse(dmgResponse)
            try fileManager.moveItem(at: downloadedDMG, to: dmgDestination)

            let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
            try validateHTTPResponse(checksumResponse)
            guard let checksumText = String(data: checksumData, encoding: .utf8),
                  let expectedChecksum = checksumText.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
                  expectedChecksum.count == 64 else {
                throw UpdateError.invalidChecksum
            }

            let actualChecksum = try await Task.detached(priority: .userInitiated) {
                try sha256(of: dmgDestination)
            }.value

            guard actualChecksum.caseInsensitiveCompare(expectedChecksum) == .orderedSame else {
                throw UpdateError.checksumMismatch
            }

            let mountPoint = try await Task.detached(priority: .userInitiated) {
                try mountDMG(dmgDestination)
            }.value

            let sourceApp = mountPoint.appendingPathComponent("FindTree.app", isDirectory: true)
            guard fileManager.fileExists(atPath: sourceApp.path) else {
                await Task.detached(priority: .utility) {
                    _ = try? runCommand(
                        executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                        arguments: ["detach", mountPoint.path, "-quiet"]
                    )
                }.value
                throw UpdateError.appMissingFromDMG
            }

            let sourceVersion = installedAppVersion(at: sourceApp)
            guard sourceVersion == release.version else {
                throw UpdateError.versionMismatch(expected: release.version, actual: sourceVersion)
            }

            let targetApp = targetApplicationURL()
            let targetDirectory = targetApp.deletingLastPathComponent()
            guard fileManager.isWritableFile(atPath: targetDirectory.path) else {
                throw UpdateError.installLocationNotWritable
            }

            return PreparedDMGUpdate(
                temporaryDirectory: temporaryDirectory,
                mountPoint: mountPoint,
                sourceApp: sourceApp,
                targetApp: targetApp
            )
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    nonisolated private static func scheduleDMGInstallAfterTermination(_ update: PreparedDMGUpdate) throws {
        let scriptURL = update.temporaryDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -u

        pid="$1"
        source_app="$2"
        target_app="$3"
        mount_point="$4"
        temp_dir="$5"

        while /bin/kill -0 "$pid" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if /usr/bin/ditto "$source_app" "$target_app"; then
          /usr/bin/hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
          /usr/bin/open "$target_app"
          /bin/rm -rf "$temp_dir"
          exit 0
        fi

        /usr/bin/hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
        /usr/bin/open "$target_app" >/dev/null 2>&1 || true
        exit 1
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            update.sourceApp.path,
            update.targetApp.path,
            update.mountPoint.path,
            update.temporaryDirectory.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated private static func scheduleRelaunchAfterTermination() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "findtree-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            targetApplicationURL().path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    nonisolated private static func homebrewExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    nonisolated private static func targetApplicationURL() -> URL {
        let currentBundle = Bundle.main.bundleURL
        if currentBundle.path.hasPrefix("/Volumes/") {
            return URL(fileURLWithPath: "/Applications/FindTree.app", isDirectory: true)
        }
        return currentBundle
    }

    nonisolated private static func installedAppVersion(at appURL: URL) -> String? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    nonisolated private static func mountDMG(_ dmgURL: URL) throws -> URL {
        let result = try runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        )

        guard result.status == 0 else {
            throw UpdateError.commandFailed(commandErrorMessage(result))
        }

        let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil)
        guard let dictionary = plist as? [String: Any],
              let entities = dictionary["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.mountFailed
        }

        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func runCommand(executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    nonisolated private static func commandErrorMessage(_ result: CommandResult) -> String {
        let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stderr, !stderr.isEmpty {
            return stderr
        }

        let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stdout, !stdout.isEmpty {
            return stdout
        }

        return "The update command failed."
    }

    nonisolated private static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateError.downloadFailed
        }
    }

    nonisolated private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsVersion = ParsedVersion(lhs)
        let rhsVersion = ParsedVersion(rhs)

        let componentCount = max(lhsVersion.numbers.count, rhsVersion.numbers.count)
        for index in 0..<componentCount {
            let lhsValue = index < lhsVersion.numbers.count ? lhsVersion.numbers[index] : 0
            let rhsValue = index < rhsVersion.numbers.count ? rhsVersion.numbers[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue ? .orderedDescending : .orderedAscending
            }
        }

        switch (lhsVersion.preRelease, rhsVersion.preRelease) {
        case (nil, nil):
            return .orderedSame
        case (nil, _):
            return .orderedDescending
        case (_, nil):
            return .orderedAscending
        case (let lhsPre?, let rhsPre?):
            let count = max(lhsPre.count, rhsPre.count)
            for index in 0..<count {
                guard index < lhsPre.count else { return .orderedAscending }
                guard index < rhsPre.count else { return .orderedDescending }

                let left = lhsPre[index]
                let right = rhsPre[index]
                if left == right { continue }

                if let leftNumber = Int(left), let rightNumber = Int(right) {
                    return leftNumber > rightNumber ? .orderedDescending : .orderedAscending
                }
                if Int(left) != nil { return .orderedAscending }
                if Int(right) != nil { return .orderedDescending }
                return left.compare(right, options: [.numeric, .caseInsensitive])
            }
            return .orderedSame
        }
    }

    nonisolated private static func userFacingMessage(for error: Error) -> String {
        if let updateError = error as? UpdateError {
            return updateError.localizedDescription
        }
        return "Update failed: \(error.localizedDescription)"
    }

    private struct ParsedVersion: Sendable {
        let numbers: [Int]
        let preRelease: [String]?

        init(_ rawValue: String) {
            let normalized = rawValue.trimmingPrefix("v")
            let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            numbers = parts.first?.split(separator: ".").map { Int($0) ?? 0 } ?? [0]
            preRelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : nil
        }
    }

    private enum UpdateError: LocalizedError {
        case releaseLookupFailed
        case releaseAssetMissing
        case downloadFailed
        case invalidChecksum
        case checksumMismatch
        case mountFailed
        case appMissingFromDMG
        case homebrewUnavailable
        case installLocationNotWritable
        case commandFailed(String)
        case versionMismatch(expected: String, actual: String?)

        var errorDescription: String? {
            switch self {
            case .releaseLookupFailed:
                return "Could not check the latest release."
            case .releaseAssetMissing:
                return "The latest release does not contain the expected DMG files."
            case .downloadFailed:
                return "Could not download the update."
            case .invalidChecksum:
                return "The release checksum is invalid."
            case .checksumMismatch:
                return "The downloaded update failed its checksum check."
            case .mountFailed:
                return "Could not mount the downloaded update."
            case .appMissingFromDMG:
                return "FindTree.app was not found in the downloaded DMG."
            case .homebrewUnavailable:
                return "Homebrew could not be found."
            case .installLocationNotWritable:
                return "FindTree cannot update this installation because its app folder is not writable."
            case .commandFailed(let message):
                return "Update failed: \(message)"
            case .versionMismatch(let expected, let actual):
                return "Update failed: expected v\(expected), but found v\(actual ?? "unknown")."
            }
        }
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        guard first == prefix else { return self }
        return String(dropFirst())
    }
}
