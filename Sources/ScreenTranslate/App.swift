import SwiftUI
import AppKit

@main
struct ScreenTranslateApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var provider: Provider = Provider(rawValue: UserDefaults.standard.string(forKey: "provider") ?? "") ?? .openAI
    @Published var status = "⌘⇧2를 눌러 번역할 영역을 선택하세요."
    @Published var busy = false
    @Published var original: NSImage?
    @Published var translated: NSImage?
    @Published var translationText = ""
    @Published var error: String?
    private let captureService = RegionCapture()
    private var task: Task<Void, Never>?
    var showResult: (() -> Void)?
    var hideWindows: (() -> Void)?

    func model(for provider: Provider) -> String {
        let stored = UserDefaults.standard.string(forKey: "model.\(provider.rawValue)") ?? ""
        return stored.isEmpty ? provider.defaultModel : stored
    }

    func capture() {
        guard !busy else { return }
        hideWindows?()
        let selectedProvider = provider
        let selectedModel = model(for: selectedProvider)
        let workspaceID = UserDefaults.standard.string(forKey: "claude.workspaceID") ?? ""
        do {
            guard try KeychainStore.contains(selectedProvider) else {
                error = "메뉴 막대 → 설정…에서 \(selectedProvider.rawValue) API 키를 등록해 주세요."
                return
            }
        } catch { self.error = error.localizedDescription; return }
        busy = true
        error = nil
        status = "영역을 드래그하세요. Esc로 취소할 수 있습니다."
        task = Task {
            defer { busy = false; task = nil }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                guard let captured = try await captureService.capture() else { status = "캡처를 취소했습니다."; return }
                try Task.checkCancellation()
                original = captured
                translated = nil
                translationText = ""
                status = "이미지에서 글자 위치를 찾고 있습니다…"
                // Bound image size for API limits and predictable rendering/memory usage.
                let scale = min(1, 2000 / max(captured.size.width, captured.size.height))
                let normalized = NSImage(size: CGSize(width: captured.size.width * scale, height: captured.size.height * scale))
                normalized.lockFocus()
                captured.draw(in: CGRect(origin: .zero, size: normalized.size))
                normalized.unlockFocus()
                guard let cgImage = normalized.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AppError("캡처 이미지를 읽을 수 없습니다.") }
                let regions = try await Task.detached(priority: .userInitiated) { try TranslationService.recognize(cgImage) }.value
                try Task.checkCancellation()
                guard !regions.isEmpty else { throw AppError("선택한 영역에서 글자를 찾지 못했습니다.") }
                guard regions.count <= 180 else { throw AppError("글자가 너무 많습니다. 180줄 이하의 작은 영역을 선택해 주세요.") }
                let png = try ImageRenderer.png(normalized)
                guard png.count <= 4_500_000 else { throw AppError("이미지가 너무 큽니다. 더 작은 영역을 선택해 주세요.") }
                status = "\(selectedProvider.rawValue)에서 \(regions.count)개 문장을 한국어로 번역하고 있습니다…"
                let key = try KeychainStore.read(selectedProvider)
                guard !key.isEmpty else { throw AppError("API 키가 삭제되었습니다. 설정에서 다시 등록해 주세요.") }
                let result = try await TranslationService.translate(provider: selectedProvider, model: selectedModel, key: key, png: png, regions: regions, workspaceID: workspaceID)
                try Task.checkCancellation()
                translated = ImageRenderer.render(original: normalized, regions: regions, payload: result)
                translationText = result.translations.sorted { $0.id < $1.id }.map(\.text).joined(separator: "\n")
                status = "번역 완료 · \(selectedProvider.rawValue) / \(selectedModel)"
                showResult?()
            } catch is CancellationError {
                status = "번역을 취소했습니다."
            } catch {
                if Task.isCancelled { status = "번역을 취소했습니다." }
                else { self.error = error.localizedDescription; status = "번역하지 못했습니다." }
            }
        }
    }

    func cancel() { task?.cancel(); captureService.cancel() }

    func saveImage() {
        guard let translated else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "번역-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ImageRenderer.png(translated).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }

    func copyImage() {
        guard let translated else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([translated])
        status = "번역 이미지를 클립보드에 복사했습니다."
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    let updates = UpdateController()
    private var statusItem: NSStatusItem!
    private let shortcut = GlobalShortcut()
    private var settingsWindow: NSWindow?
    private var resultWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "ScreenTranslate")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let status = menu.addItem(withTitle: state.status, action: nil, keyEquivalent: "")
        status.tag = 10
        status.isEnabled = false
        menu.addItem(.separator())
        let capture = menu.addItem(withTitle: "영역 번역  ⌘⇧2", action: #selector(startCapture), keyEquivalent: "")
        capture.target = self
        capture.tag = 11
        let result = menu.addItem(withTitle: "번역 결과 보기", action: #selector(openResult), keyEquivalent: "")
        result.target = self
        result.tag = 12
        let cancel = menu.addItem(withTitle: "번역 취소", action: #selector(cancelTranslation), keyEquivalent: "")
        cancel.target = self
        cancel.tag = 13
        let settings = menu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let update = menu.addItem(withTitle: "업데이트 확인…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        update.tag = 14
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        state.showResult = { [weak self] in self?.openResult() }
        state.hideWindows = { [weak self] in self?.settingsWindow?.orderOut(nil); self?.resultWindow?.orderOut(nil) }
        shortcut.action = { [weak self] in self?.state.capture() }
        do { try shortcut.register() } catch { state.error = error.localizedDescription }
        updates.checkAtLaunch()
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { state.cancel() }
    @objc private func startCapture() { state.capture() }
    @objc private func checkForUpdates() { updates.checkForUpdates() }
    @objc private func cancelTranslation() { state.cancel() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 10)?.title = state.error ?? state.status
        menu.item(withTag: 11)?.isEnabled = !state.busy
        menu.item(withTag: 12)?.isEnabled = !state.busy && state.translated != nil
        menu.item(withTag: 13)?.isEnabled = state.busy
        menu.item(withTag: 14)?.isEnabled = updates.canCheck && !state.busy
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = window(title: "ScreenTranslate 설정", size: NSSize(width: 520, height: 640), view: SettingsView(state: state, updates: updates)) }
        activate(settingsWindow!)
    }

    @objc func openResult() {
        guard state.translated != nil else { return }
        if resultWindow == nil {
            let result = window(title: "ScreenTranslate · 한국어 번역", size: NSSize(width: 1200, height: 760), view: ResultView(state: state))
            result.level = .floating
            result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            result.hidesOnDeactivate = false
            resultWindow = result
        }
        activate(resultWindow!)
    }

    // AppKit owns the only settings window; no SwiftUI Settings scene is created.
    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ScreenTranslate")
        appMenu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        for (title, action, key) in [("실행 취소", "undo:", "z"), ("잘라내기", "cut:", "x"),
                                     ("복사", "copy:", "c"), ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func window<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }
    private func activate(_ window: NSWindow) { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var updates: UpdateController
    @State private var key = ""
    @State private var hasKey = false
    @State private var model = ""
    @State private var saved = false
    @State private var workspaceID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("ScreenTranslate", systemImage: "character.bubble.fill").font(.largeTitle.bold())
            Text("화면 속 외국어를 한국어로 · ⌘⇧2").foregroundStyle(.secondary)
            Picker("번역 서비스", selection: $state.provider) { ForEach(Provider.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            SecureField(hasKey ? "새 API 키 입력 (비워두면 기존 키 유지)" : "API 키", text: $key).textFieldStyle(.roundedBorder)
            HStack {
                Text(hasKey ? "API 키가 키체인에 저장되어 있습니다." : "등록된 API 키가 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if hasKey {
                    Button("키 삭제", role: .destructive) {
                        do { try KeychainStore.save("", provider: state.provider); key = ""; hasKey = false }
                        catch { state.error = error.localizedDescription }
                    }
                }
            }
            if state.provider == .claude {
                TextField("워크스페이스 ID (필요한 키만 입력)", text: $workspaceID).textFieldStyle(.roundedBorder)
                Text("워크스페이스에 연결되지 않은 API 키는 이 값이 필요합니다. Claude API 콘솔의 워크스페이스 ID를 입력하세요. 연결된 키는 비워 두셔도 됩니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("모델 ID", text: $model).textFieldStyle(.roundedBorder)
            Text("기본 모델: \(state.provider.defaultModel)").font(.caption).foregroundStyle(.secondary)
            Text("영역 선택을 완료하면 선택한 이미지와 인식한 텍스트가 해당 API로 전송됩니다. API 사용료가 발생할 수 있습니다. 키는 이 Mac의 키체인에 저장됩니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("저장") {
                    do {
                        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            try KeychainStore.save(key, provider: state.provider)
                            hasKey = true
                        }
                        key = ""
                        if state.provider == .claude {
                            UserDefaults.standard.set(workspaceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "claude.workspaceID")
                        }
                        UserDefaults.standard.set(state.provider.rawValue, forKey: "provider")
                        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "model.\(state.provider.rawValue)")
                        UserDefaults.standard.set(true, forKey: "configured")
                        state.error = nil
                        saved = true
                    } catch { state.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                Button("영역 번역") { state.capture() }.disabled(state.busy)
                if saved { Text("저장되었습니다").font(.caption).foregroundStyle(.green) }
            }
            if let error = state.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("버전 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "개발"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("업데이트 확인…") { updates.checkForUpdates() }.disabled(!updates.canCheck || state.busy)
            }
        }.padding(28).frame(minWidth: 460, minHeight: 400)
            .onAppear { load() }.onChange(of: state.provider) { _ in load() }
            .onDisappear { key = "" }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in key = "" }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in key = "" }
    }
    private func load() {
        saved = false
        workspaceID = UserDefaults.standard.string(forKey: "claude.workspaceID") ?? ""
        model = state.model(for: state.provider)
        key = ""
        do { hasKey = try KeychainStore.contains(state.provider) } catch { hasKey = false; state.error = error.localizedDescription }
    }
}

struct ResultView: View {
    @ObservedObject var state: AppState
    @State private var showText = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("한국어 화면 번역", systemImage: "character.bubble").font(.headline)
                Spacer()
                Toggle("번역 텍스트", isOn: $showText).toggleStyle(.button)
                Button("복사") { state.copyImage() }.disabled(state.translated == nil)
                Button("PNG 저장") { state.saveImage() }.disabled(state.translated == nil)
                Button("새 캡처") { state.capture() }.disabled(state.busy)
            }.padding()
            Divider()
            if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding() }
            Group {
                let imageSize = state.original?.size ?? .zero
                let stacked = imageSize.width / max(1, imageSize.height) >= 2.2
                if stacked {
                    VStack(spacing: 16) {
                        comparisonPanel(title: "원본", image: state.original,
                                        placeholder: "⌘⇧2로 번역할 영역을 선택하세요.")
                        Divider()
                        comparisonPanel(title: "한국어 번역", image: state.translated,
                                        placeholder: state.busy ? "번역 중입니다…" : "번역 이미지가 여기에 표시됩니다.")
                    }
                } else {
                    HStack(spacing: 16) {
                        comparisonPanel(title: "원본", image: state.original,
                                        placeholder: "⌘⇧2로 번역할 영역을 선택하세요.")
                        Divider()
                        comparisonPanel(title: "한국어 번역", image: state.translated,
                                        placeholder: state.busy ? "번역 중입니다…" : "번역 이미지가 여기에 표시됩니다.")
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.04))
            if showText { ScrollView { Text(state.translationText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.frame(height: 160) }
            Divider()
            HStack {
                if state.busy { ProgressView().controlSize(.small) }
                Text(state.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if state.busy { Button("취소") { state.cancel() } }
            }.padding(12)
        }.frame(minWidth: 720, minHeight: 440)
    }

    private func comparisonPanel(title: String, image: NSImage?, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).frame(height: 20).padding(.horizontal, 4)
            GeometryReader { proxy in
                if let image {
                    let fitted = ComparisonSizing.fit(image.size, inside: proxy.size)
                    Image(nsImage: image).resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .background(Color.white)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "viewfinder").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(placeholder).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Preserve aspect ratio, fit both axes, and never enlarge small captures.
enum ComparisonSizing {
    static func fit(_ image: CGSize, inside available: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(1, available.width / image.width, available.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
