import Combine
import Foundation
import Security

enum DefaultFormatPreset: String, CaseIterable, Identifiable, Codable {
    case best
    case balanced
    case audioOnly
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "最佳畫質"
        case .balanced: return "平衡"
        case .audioOnly: return "僅音訊"
        case .custom: return "自訂"
        }
    }

    var subtitle: String {
        switch self {
        case .best: return "優先最高解析度，必要時合併影音軌"
        case .balanced: return "約 720p，較省時間與空間"
        case .audioOnly: return "只保留音訊（m4a／opus）"
        case .custom: return "每次手動選格式"
        }
    }

    var ytDlpFormat: String {
        switch self {
        case .best:
            return "bestvideo*+bestaudio/best"
        case .balanced:
            return "bestvideo[height<=720]+bestaudio/best[height<=720]/best"
        case .audioOnly:
            return "bestaudio/bestaudio*/best"
        case .custom:
            return "best"
        }
    }
}

final class AppSettings: ObservableObject {
    @Published var moviesRootPath: String
    @Published var defaultFormat: DefaultFormatPreset
    @Published var filenameTemplate: String
    @Published var concurrency: Int
    @Published var watchClipboard: Bool
    @Published var retainHistory: Bool
    @Published var cookieFilePath: String
    @Published var ytdlpPath: String
    @Published var ffmpegPath: String
    @Published var includeMicrophoneByDefault: Bool
    @Published var trimOutputDirectory: String

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        moviesRootPath = defaults.string(forKey: Key.moviesRoot) ?? AppPaths.defaultMoviesRoot().path
        if let raw = defaults.string(forKey: Key.defaultFormat),
           let preset = DefaultFormatPreset(rawValue: raw) {
            defaultFormat = preset
        } else {
            defaultFormat = .best
        }
        filenameTemplate = defaults.string(forKey: Key.filenameTemplate) ?? "%(title)s [%(id)s].%(ext)s"
        let storedConcurrency = defaults.object(forKey: Key.concurrency) as? Int ?? 1
        concurrency = min(2, max(1, storedConcurrency))
        watchClipboard = defaults.object(forKey: Key.watchClipboard) as? Bool ?? false
        retainHistory = defaults.object(forKey: Key.retainHistory) as? Bool ?? true
        cookieFilePath = KeychainStore.load(account: Key.cookieFile) ?? defaults.string(forKey: Key.cookieFile) ?? ""
        ytdlpPath = defaults.string(forKey: Key.ytdlpPath) ?? ""
        ffmpegPath = defaults.string(forKey: Key.ffmpegPath) ?? ""
        includeMicrophoneByDefault = defaults.bool(forKey: Key.includeMic)
        trimOutputDirectory = defaults.string(forKey: Key.trimOutput) ?? ""

        $moviesRootPath.sink { [weak self] in self?.defaults.set($0, forKey: Key.moviesRoot) }.store(in: &cancellables)
        $defaultFormat.sink { [weak self] in self?.defaults.set($0.rawValue, forKey: Key.defaultFormat) }.store(in: &cancellables)
        $filenameTemplate.sink { [weak self] in self?.defaults.set($0, forKey: Key.filenameTemplate) }.store(in: &cancellables)
        $concurrency.sink { [weak self] in self?.defaults.set($0, forKey: Key.concurrency) }.store(in: &cancellables)
        $watchClipboard.sink { [weak self] in self?.defaults.set($0, forKey: Key.watchClipboard) }.store(in: &cancellables)
        $retainHistory.sink { [weak self] in self?.defaults.set($0, forKey: Key.retainHistory) }.store(in: &cancellables)
        $ytdlpPath.sink { [weak self] in self?.defaults.set($0, forKey: Key.ytdlpPath) }.store(in: &cancellables)
        $ffmpegPath.sink { [weak self] in self?.defaults.set($0, forKey: Key.ffmpegPath) }.store(in: &cancellables)
        $includeMicrophoneByDefault.sink { [weak self] in self?.defaults.set($0, forKey: Key.includeMic) }.store(in: &cancellables)
        $trimOutputDirectory.sink { [weak self] in self?.defaults.set($0, forKey: Key.trimOutput) }.store(in: &cancellables)
        $cookieFilePath.sink { path in
            KeychainStore.save(account: Key.cookieFile, value: path)
            defaults.set(path.isEmpty ? nil : "<set>", forKey: Key.cookieFilePresent)
        }.store(in: &cancellables)
    }

    var moviesRootURL: URL {
        URL(fileURLWithPath: moviesRootPath, isDirectory: true)
    }

    var cookieFileURL: URL? {
        let trimmed = cookieFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    func applyImportedCookieFile(_ url: URL) {
        cookieFilePath = url.path
    }

    func clearCookieFile() {
        cookieFilePath = ""
        KeychainStore.delete(account: Key.cookieFile)
    }

    private enum Key {
        static let moviesRoot = "settings.moviesRoot"
        static let defaultFormat = "settings.defaultFormat"
        static let filenameTemplate = "settings.filenameTemplate"
        static let concurrency = "settings.concurrency"
        static let watchClipboard = "settings.watchClipboard"
        static let retainHistory = "settings.retainHistory"
        static let cookieFile = "settings.cookieFilePath"
        static let cookieFilePresent = "settings.cookieFilePresent"
        static let ytdlpPath = "settings.ytdlpPath"
        static let ffmpegPath = "settings.ffmpegPath"
        static let includeMic = "settings.includeMic"
        static let trimOutput = "settings.trimOutputDirectory"
    }
}

enum KeychainStore {
    private static let service = "app.framekeep.Framekeep"

    static func save(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
