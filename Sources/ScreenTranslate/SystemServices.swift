import AppKit
import Carbon
import Security

struct KeychainStore {
    private static func query(_ provider: Provider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.screentranslate.api-key",
         kSecAttrAccount as String: provider.rawValue]
    }

    static func contains(_ provider: Provider) throws -> Bool {
        var request = query(provider)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AppError("키체인 상태 확인 실패 (\(status)).") }
        return true
    }

    static func read(_ provider: Provider) throws -> String {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError("키체인 읽기 실패 (\(status)).")
        }
        return key
    }

    static func save(_ key: String, provider: Provider) throws {
        let query = query(provider)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError("키체인 삭제 실패 (\(status)).") }
            return
        }
        let values = [kSecValueData as String: Data(trimmed.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query.merging(values) { _, new in new }
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("키체인 저장 실패 (\(status)).") }
    }
}

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    func register() throws {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action?()
            }
            return noErr
        }, 1, &type, pointer, &handler)
        guard handlerStatus == noErr else { throw AppError("단축키 이벤트를 등록할 수 없습니다.") }
        let id = EventHotKeyID(signature: 0x5354524E, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_2), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { throw AppError("⌘⇧2 단축키를 등록할 수 없습니다. 다른 앱의 단축키 설정을 확인해 주세요.") }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class RegionCapture {
    private var process: Process?

    func capture() async throws -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw AppError("시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 ScreenTranslate를 허용한 뒤 앱을 다시 실행해 주세요.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenTranslate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("capture.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-s", "-x", "-t", "png", file.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        process = task
        defer { process = nil }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            // screencapture exits nonzero for Escape too; no file means a cancelled selection.
            return nil
        }
        guard status == 0, let image = NSImage(contentsOf: file) else { throw AppError("화면 캡처에 실패했습니다.") }
        return image
    }

    func cancel() { process?.terminate() }
}
