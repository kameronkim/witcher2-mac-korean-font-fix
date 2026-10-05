import Foundation
import Darwin

enum PatchAction: Sendable { case install, remove }

struct PatchService: Sendable {
    var isRunning: @Sendable (URL) throws -> Bool = { try gameIsRunning(at: $0) }
    static let fontFiles = ["CookedPC/globals/gui/fonts.swf", "CookedPC/globals/gui/fonts/fonts.csv"]

    struct LanguageSettingError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    static func userINI(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/com.cdprojektred.TheWitcher2/GameDocuments/Witcher 2/config/User.ini")
    }

    func setKoreanLanguage(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let ini = Self.userINI(home: home)
        var text = FileManager.default.fileExists(atPath: ini.path) ? try String(contentsOf: ini, encoding: .utf8) : ""
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let setting = try NSRegularExpression(pattern: #"(?m)^(\h*Language\h*=\h*)[^\r\n]*"#)
        let range = NSRange(text.startIndex..., in: text)
        if setting.firstMatch(in: text, range: range) != nil {
            text = setting.stringByReplacingMatches(in: text, range: range, withTemplate: "$1KR")
        } else if let section = text.range(of: #"(?m)^\[linux\]\h*\r?(?:\n|$)"#, options: .regularExpression) {
            let separator = text[section].hasSuffix("\n") ? "" : newline
            text.insert(contentsOf: separator + "Language=KR" + newline, at: section.upperBound)
        } else {
            if !text.isEmpty && !text.hasSuffix("\n") { text += newline }
            text += "[linux]" + newline + "Language=KR" + newline
        }
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: ini, atomically: true, encoding: .utf8)
    }

    enum ServiceError: LocalizedError {
        case invalidFolder, running, processInspection
        var errorDescription: String? {
            switch self {
            case .invalidFolder: return "유효한 The Witcher 2 Steam 게임 폴더가 아닙니다."
            case .running: return "게임이 실행 중이므로 이 작업을 수행할 수 없습니다."
            case .processInspection: return "게임 실행 상태를 확인할 수 없어 이 작업을 수행하지 않습니다."
            }
        }
    }

    static func gameFolder(from url: URL) -> URL? {
        let folder = url.pathExtension.lowercased() == "app" ? url.deletingLastPathComponent() : url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("The Witcher 2.app").path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("CookedPC/krbr.dzip").path) else { return nil }
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }

    static func hasKoreanSetting(_ text: String) -> Bool {
        text.range(of: #"(?m)^\h*Language\h*=\h*KR\h*\r?$"#, options: .regularExpression) != nil
    }

    func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [URL] {
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        var libraries = [steam]
        if FileManager.default.fileExists(atPath: vdf.path) {
            let text = try String(contentsOf: vdf, encoding: .utf8)
            let pattern = try NSRegularExpression(pattern: #"(?m)^\h*"path"\h*"((?:\\.|[^"\\])*)""#)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var path = "", escaped = false
                for character in text[range] {
                    if escaped {
                        if character != "\\" && character != "\"" { path.append("\\") }
                        path.append(character)
                        escaped = false
                    } else if character == "\\" { escaped = true }
                    else { path.append(character) }
                }
                if !path.isEmpty { libraries.append(URL(fileURLWithPath: path)) }
            }
        }
        var seen = Set<String>()
        return libraries.compactMap {
            guard let folder = Self.gameFolder(from: $0.appendingPathComponent("steamapps/common/the witcher 2")),
                  seen.insert(folder.path).inserted else { return nil }
            return folder
        }
    }

    static func gameIsRunning(at folder: URL) throws -> Bool {
        let target = folder.appendingPathComponent("The Witcher 2.app/Contents/MacOS/The Witcher 2").resolvingSymlinksInPath().path
        // A game launched by this user is in this UID's process list. Do not inspect other users' processes.
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard needed > 0 else { throw ServiceError.processInspection }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 256)
        let capacity = pids.count * MemoryLayout<pid_t>.size
        let length = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32(capacity)) }
        guard length > 0, length < capacity else { throw ServiceError.processInspection }
        for pid in pids.prefix(Int(length) / MemoryLayout<pid_t>.size) where pid > 0 {
            // PROC_PIDPATHINFO_MAXSIZE is a C macro (4 * MAXPATHLEN), not imported by Swift.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let result = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            if result <= 0 {
                // Processes can exit between enumeration and path lookup.
                if errno == ESRCH || errno == ENOENT { continue }
                throw ServiceError.processInspection
            }
            let actual = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
            if actual == target { return true }
        }
        return false
    }

    private func check(_ folder: URL) throws {
        guard Self.gameFolder(from: folder) != nil else { throw ServiceError.invalidFolder }
        if try isRunning(folder) { throw ServiceError.running }
    }

    func inspect(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstallationState {
        guard Self.gameFolder(from: folder) != nil else { return InstallationState() }
        let ini = Self.userINI(home: home)
        let setting = try? String(contentsOf: ini, encoding: .utf8)
        let korean = setting.map(Self.hasKoreanSetting) ?? false
        let languageKnown = setting?.range(of: #"(?m)^\h*Language\h*=\h*\S+\h*\r?$"#, options: .regularExpression) != nil
        let count = Self.fontFiles.filter {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path, isDirectory: &directory) && !directory.boolValue
        }.count
        do {
            try check(folder)
            return InstallationState(found: true, fontCount: count, korean: korean, languageKnown: languageKnown, canModify: true)
        } catch {
            return InstallationState(found: true, fontCount: count, korean: korean, languageKnown: languageKnown, restriction: error.localizedDescription)
        }
    }

    func install(at folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try check(folder)
        let font = try DzipExtractor.extract(from: folder.appendingPathComponent("CookedPC/krbr.dzip"))
        // Check again after extraction, immediately before changing the target files.
        try check(folder)
        let csv = folder.appendingPathComponent(Self.fontFiles[1])
        try FileManager.default.createDirectory(at: csv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try font.write(to: folder.appendingPathComponent(Self.fontFiles[0]), options: .atomic)
        let text = "FontAlias;FontName;FontName_ZH;FontName_JP;FontName_KR\n" +
            "Font_Style_Standard;NanumGothic Bold;PMingLiU;YOzFontM90;NanumGothic Bold\n" +
            "Font_Style_Black;NanumGothic Bold;PMingLiU;YOzFontM90;NanumGothic Bold\n"
        let body = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        try body.write(to: csv, options: .atomic)
        do {
            try check(folder)
            try setKoreanLanguage(home: home)
        } catch {
            throw LanguageSettingError(underlying: error)
        }
    }

    func remove(at folder: URL) throws {
        try check(folder)
        for relative in Self.fontFiles {
            let path = folder.appendingPathComponent(relative).path
            // unlink never recursively deletes a directory at a patch-file path.
            if unlink(path) != 0 && errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
            }
        }
        _ = rmdir(folder.appendingPathComponent(Self.fontFiles[1]).deletingLastPathComponent().path)
    }
}

struct InstallationState: Sendable {
    var found = false
    var fontCount = 0
    var korean = false
    var languageKnown = true
    var canModify = false
    var restriction = ""
    var installed: Bool { fontCount == 2 }
}
