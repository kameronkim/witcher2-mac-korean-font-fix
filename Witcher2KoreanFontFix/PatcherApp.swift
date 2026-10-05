import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Sampled from the app icon's red eyes, softened toward gray for the dark UI.
private let witcherAccent = Color(red: 0.71, green: 0.39, blue: 0.37)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: PatchModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.busy == true ? .terminateCancel : .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model?.busy != true }
}

struct PatcherView: View {
    @ObservedObject var model: PatchModel
    let delegate: AppDelegate
    @State private var dropTargeted = false
    @State private var githubHovered = false

    private var guidance: String {
        if model.needsLocation { return model.failed ? model.message : "" }
        return model.failed && model.lastAction == nil ? model.message : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("THE WITCHER \(Text("2").foregroundColor(witcherAccent)) KOREAN FONT FIX")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.26).lineLimit(1)
                Spacer()
                extraActions
            }.frame(height: 20).padding(.bottom, 20)
            VStack(alignment: .leading, spacing: -4) {
                Text("THE WITCHER \(Text("2").foregroundColor(witcherAccent))")
                Text("In Korean.").foregroundStyle(Color(white: 0.59))
            }.font(.system(size: 40, weight: .semibold)).tracking(-1.8)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.isSearching {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                if model.showsProgress {
                                    ProgressView().controlSize(.small).colorMultiply(witcherAccent)
                                }
                                Text("게임을 찾는 중입니다.").font(.system(size: 16, weight: .medium))
                            }
                            inlineAction("게임 폴더 선택…", action: model.chooseFolder)
                        }.padding(.top, 12)
                    } else if let heading = model.heading {
                        exception(heading)
                    } else {
                        statusStrip
                        if !model.busy && !model.message.isEmpty {
                            Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.top, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }.padding(.vertical, 12)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 14) {
                Link(destination: URL(string: "https://github.com/kameronkim/witcher2-mac-korean-font-fix")!) {
                    HStack(spacing: 6) {
                        Text("GitHub").font(.system(size: 12, design: .monospaced)).underline(githubHovered)
                        Image(systemName: "arrow.up.right").font(.system(size: 12))
                    }
                }.onHover { githubHovered = $0 }
                    .accessibilityLabel("The Witcher 2 한국어 폰트 수정 GitHub 저장소")
                Spacer()
                Text("Steam · macOS").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).frame(height: 20).padding(.top, 12)
        }
        .padding(.horizontal, 20).padding(.vertical, 16).frame(width: 520, height: 360)
        .background(Color(red: 0.051, green: 0.051, blue: 0.055))
        .foregroundStyle(Color(red: 0.925, green: 0.925, blue: 0.91))
        .preferredColorScheme(.dark)
        .tint(witcherAccent)
        .overlay(Rectangle().stroke(dropTargeted ? Color.gray : .clear, lineWidth: 2).padding(4).allowsHitTesting(false))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard model.canChooseLocation, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.select(url) }
            }
            return true
        }
        .onAppear { delegate.model = model; NSApp.windows.first?.delegate = delegate }
    }

    private var extraActions: some View {
        Menu {
            Button("다시 확인") { Task { await model.refresh() } }.disabled(model.busy)
            if let folder = model.folder {
                Button("게임 폴더 보기") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.disabled(model.busy)
            }
            Button("게임 폴더 변경…", action: model.chooseFolder).disabled(model.busy)
            if model.state.installed {
                Divider()
                Button("다시 설치") { Task { await model.apply(.install) } }.disabled(!model.canAct)
                if model.primaryAction == .install {
                    Button("제거") { Task { await model.apply(.remove) } }.disabled(!model.canAct)
                }
            }
        } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("추가 작업")
        .disabled(model.busy)
    }

    private func exception(_ heading: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading.0 + " " + heading.1)
                .font(.system(size: 16, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if !guidance.isEmpty {
                Text(guidance).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if model.needsLocation {
                    inlineAction("게임 폴더 선택…", action: model.chooseFolder)
                    inlineAction("다시 찾기") { Task { await model.discover() } }
                } else if !model.state.canModify {
                    inlineAction("다시 확인") { Task { await model.refresh() } }
                } else if let action = model.lastAction {
                    inlineAction("다시 시도") { Task { await model.apply(action) } }
                } else {
                    inlineAction("게임 폴더 선택…", action: model.chooseFolder)
                }
            }
        }.padding(.top, 12)
    }

    private var statusStrip: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                statusLabel("언어")
                HStack(spacing: 4) {
                    cellValue(model.state.korean ? "한국어" : (model.state.languageKnown ? "다른 언어" : "확인 불가"), checking: model.showsProgress && model.isCheckingState)
                    Spacer(minLength: 4)
                }.frame(height: 36)
            }.frame(width: 204, alignment: .leading).padding(.trailing, 24)
            VStack(alignment: .leading, spacing: 8) {
                statusLabel("패치")
                HStack(spacing: 4) {
                    cellValue(model.patchStatus, checking: model.showsProgress)
                    Spacer(minLength: 0)
                    inlineAction(model.primaryAction == .remove ? "제거" : "설치") {
                        Task { await model.apply(model.primaryAction) }
                    }.disabled(!model.canAct)
                }.frame(height: 36)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: 66)
    }

    private func statusLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func cellValue(_ value: String, checking: Bool) -> some View {
        HStack(spacing: 8) {
            if checking { ProgressView().controlSize(.small).colorMultiply(witcherAccent).accessibilityLabel(model.patchStatus) }
            if !checking || !model.isCheckingState {
                Text(value).font(.system(size: 21, weight: .medium)).tracking(-0.6).lineLimit(1).fixedSize()
            }
        }
    }

    private func inlineAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .lineLimit(1).fixedSize().padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
        }.buttonStyle(FlatActionStyle()).accessibilityLabel(title)
    }

}

private struct FlatActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        FlatActionLabel(configuration: configuration, enabled: enabled)
    }
    private struct FlatActionLabel: View {
        let configuration: ButtonStyle.Configuration
        let enabled: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(enabled && (hovered || configuration.isPressed) ? witcherAccent : Color(white: enabled ? 0.93 : 0.4))
                .background(Color.white.opacity(configuration.isPressed ? 0.08 : (hovered && enabled ? 0.04 : 0)))
                .animation(.easeOut(duration: 0.14), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

#if !UI_PREVIEW
@main
struct PatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = PatchModel()
    var body: some Scene {
        Window("The Witcher 2 Korean Font Fix", id: "patcher") {
            PatcherView(model: model, delegate: delegate).task { await model.discover() }
        }.defaultSize(width: 520, height: 360).windowResizability(.contentSize)
    }
}
#endif
