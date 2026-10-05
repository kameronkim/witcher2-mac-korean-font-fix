import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class PatchModel: ObservableObject {
    @Published var folder: URL?
    @Published var state = InstallationState()
    @Published var busy = false {
        didSet {
            showsProgress = busy
        }
    }
    @Published private(set) var showsProgress = false
    @Published var message = ""
    @Published var failed = false
    @Published var lastAction: PatchAction?
    let service = PatchService()
    private var discovery: Task<[URL], Error>?

    var isCheckingState: Bool { busy && lastAction == nil }
    var isSearching: Bool { isCheckingState && folder == nil }
    var canChooseLocation: Bool { !busy || isSearching }
    var gameRunning: Bool { state.restriction.contains("게임이 실행") }
    var needsLocation: Bool { folder == nil || (!busy && !state.found) }
    var canAct: Bool { !busy && state.found && state.canModify }
    var patchInstalled: Bool { state.installed && state.korean && state.languageKnown }
    var primaryAction: PatchAction { patchInstalled ? .remove : .install }
    var patchStatus: String {
        if showsProgress && isCheckingState { return "확인 중" }
        if showsProgress { return lastAction == .remove ? "제거 중" : "설치 중" }
        return patchInstalled ? "설치됨" : "설치 필요"
    }

    var heading: (String, String)? {
        if busy { return nil }
        if folder == nil { return ("게임을", "찾을 수 없습니다.") }
        if failed, let lastAction {
            return (lastAction == .remove ? "제거하지" : "설치하지", "못했습니다.")
        }
        if !state.found { return ("게임을", "찾을 수 없습니다.") }
        if !state.canModify { return gameRunning ? ("게임을", "종료해 주세요.") : ("게임 실행 상태를", "확인할 수 없습니다.") }
        if failed { return ("선택한 폴더를", "사용할 수 없습니다.") }
        return nil
    }

    var languageGuidance: String {
        "언어를 한국어로 설정하지 못했습니다."
    }

    private func clearResult() {
        message = ""
        failed = false
        lastAction = nil
    }

    func discover() async {
        guard !busy else { return }
        busy = true
        clearResult()
        folder = nil
        state = InstallationState()
        let service = service
        let task = Task.detached { try service.discover() }
        discovery = task
        do {
            let locations = try await task.value
            guard !task.isCancelled else { return }
            discovery = nil
            busy = false
            // Discovery orders the default Steam library before external libraries.
            if let first = locations.first { await select(first) }
        } catch {
            guard !task.isCancelled else { return }
            discovery = nil
            busy = false
            report("게임 설치 위치를 확인하지 못했습니다. 직접 위치를 선택해 주세요.")
        }
    }

    func select(_ url: URL) async {
        guard canChooseLocation else { return }
        cancelDiscovery()
        guard let valid = PatchService.gameFolder(from: url) else {
            report("유효한 The Witcher 2 Steam 게임 폴더가 아닙니다.")
            return
        }
        folder = valid
        await refresh()
    }

    func chooseFolder() {
        guard canChooseLocation, let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        cancelDiscovery()
        let panel = NSOpenPanel()
        panel.title = "The Witcher 2 게임 위치 선택"
        panel.prompt = "선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle, .folder]
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self.select(url) }
        }
    }

    private func cancelDiscovery() {
        guard isSearching else { return }
        discovery?.cancel()
        discovery = nil
        busy = false
    }

    func refresh() async {
        guard !busy else { return }
        guard let folder else { await discover(); return }
        clearResult()
        busy = true
        let service = service
        state = await Task.detached { service.inspect(folder) }.value
        busy = false
    }

    func apply(_ action: PatchAction) async {
        guard !busy, state.canModify, let folder else { return }
        busy = true
        clearResult()
        lastAction = action
        let service = service
        do {
            try await Task.detached {
                switch action {
                case .install: try service.install(at: folder)
                case .remove: try service.remove(at: folder)
                }
            }.value
            state = await Task.detached { service.inspect(folder) }.value
            failed = false
        } catch is PatchService.LanguageSettingError {
            state = await Task.detached { service.inspect(folder) }.value
            message = languageGuidance
        } catch {
            state = await Task.detached { service.inspect(folder) }.value
            report("", action: action)
        }
        busy = false
    }

    func report(_ text: String, action: PatchAction? = nil) {
        lastAction = action
        failed = true
        message = text
    }
}
