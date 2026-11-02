import XCTest
import AppKit
@testable import ScreenTranslate

final class TranslationTests: XCTestCase {
    @MainActor
    func testResultWindowRequiresCompletedImage() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let count = NSApp.windows.filter { $0.title == "ScreenTranslate · 한국어 번역" }.count
        delegate.openResult()
        delegate.state.error = "권한 오류"
        delegate.openResult()
        delegate.state.original = NSImage(size: NSSize(width: 100, height: 100))
        delegate.openResult()
        XCTAssertEqual(NSApp.windows.filter { $0.title == "ScreenTranslate · 한국어 번역" }.count, count)
        XCTAssertFalse(delegate.applicationShouldRestoreApplicationState(NSApp))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    }

    @MainActor
    func testOCRAndImageComposition() throws {
        _ = NSApplication.shared
        let source = NSImage(size: NSSize(width: 600, height: 180))
        source.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 180).fill()
        ("Hello world" as NSString).draw(at: NSPoint(x: 30, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
        source.unlockFocus()
        let image = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let regions = try TranslationService.recognize(image)
        XCTAssertTrue(regions.contains { $0.text.lowercased().contains("hello") })
        let payload = TranslationPayload(translations: regions.map { TranslatedRegion(id: $0.id, text: "안녕하세요") })
        let rendered = ImageRenderer.render(original: source, regions: regions, payload: payload)
        XCTAssertEqual(rendered.size, source.size)
        let png = try ImageRenderer.png(rendered)
        XCTAssertNotNil(NSBitmapImageRep(data: png))
        XCTAssertNotEqual(png, try ImageRenderer.png(source))
    }

    func testAPIFailureRedactsSecretsAndKeepsReason() throws {
        let json: [String: Any] = ["error": ["type": "invalid_request_error", "message": "credit balance too low; secret-key; PRIVATE OCR; sk-ant-example123"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let message = APIFailure.message(data: data, status: 400, provider: .claude, secrets: ["secret-key", "PRIVATE OCR"])
        XCTAssertTrue(message.contains("credit balance too low"))
        XCTAssertTrue(message.contains("invalid_request_error"))
        XCTAssertTrue(message.contains("잔액"))
        XCTAssertFalse(message.contains("secret-key"))
        XCTAssertFalse(message.contains("PRIVATE OCR"))
        XCTAssertFalse(message.contains("sk-ant-example123"))
    }

    func testNonJSONErrorDoesNotExposeBody() {
        let message = APIFailure.message(data: Data("<html>private proxy response</html>".utf8), status: 502, provider: .claude, secrets: [])
        XCTAssertTrue(message.contains("502"))
        XCTAssertFalse(message.contains("private proxy response"))
    }

    func testAPIRedirectIsRejected() throws {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])!
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    @MainActor
    func testUpdaterDoesNotStartOrOpenWindowOnInitialization() {
        _ = NSApplication.shared
        let count = NSApp.windows.count
        let updates = UpdateController()
        XCTAssertTrue(updates.canCheck)
        XCTAssertEqual(NSApp.windows.count, count)
    }

    func testValidAndFencedTranslation() throws {
        let json = #"{"translations":[{"id":2,"text":"안녕하세요"},{"id":5,"text":"설정"}]}"#
        XCTAssertEqual(try TranslationPayload.parse(json, expectedIDs: [2, 5]).translations.count, 2)
        XCTAssertEqual(try TranslationPayload.parse("```json\n\(json)\n```", expectedIDs: [2, 5]).translations.first?.text, "안녕하세요")
    }

    func testRejectsMissingDuplicateUnknownAndEmptyTranslations() {
        for json in [
            #"{"translations":[{"id":0,"text":"번역"}]}"#,
            #"{"translations":[{"id":0,"text":"번역"},{"id":0,"text":"중복"}]}"#,
            #"{"translations":[{"id":0,"text":"번역"},{"id":2,"text":"알 수 없음"}]}"#,
            #"{"translations":[{"id":0,"text":"번역"},{"id":1,"text":" "}]}"#
        ] { XCTAssertThrowsError(try TranslationPayload.parse(json, expectedIDs: [0, 1])) }
    }

    func testWorkspaceHeaderIsClaudeOnlyAndRejectsControlCharacters() throws {
        for provider in Provider.allCases {
            let request = try TranslationService.makeRequest(provider: provider, model: "test", key: "test", png: Data(), regions: [], workspaceID: "  wrk_test  ")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-workspace-id"), provider == .claude ? "wrk_test" : nil)
        }
        let blank = try TranslationService.makeRequest(provider: .claude, model: "test", key: "test", png: Data(), regions: [])
        XCTAssertNil(blank.value(forHTTPHeaderField: "anthropic-workspace-id"))
        XCTAssertThrowsError(try TranslationService.makeRequest(provider: .claude, model: "test", key: "test", png: Data(), regions: [], workspaceID: "wrk\r\nInjected: value"))
    }

    func testProviderRequestContracts() throws {
        let regions = [TextRegion(id: 0, text: "Hello", rect: .zero)]
        for provider in Provider.allCases {
            let request = try TranslationService.makeRequest(provider: provider, model: "test-model", key: "test-secret", png: Data([1, 2, 3]), regions: regions)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "test-model")
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-secret"))
            if provider == .openAI {
                XCTAssertEqual(request.url?.host, "api.openai.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
                XCTAssertEqual(json["store"] as? Bool, false)
                XCTAssertNotNil(json["input"])
            } else {
                XCTAssertEqual(request.url?.host, "api.anthropic.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
                XCTAssertNotNil(json["messages"])
            }
        }
    }

    func testExtractsProviderTextAndRejectsTruncation() throws {
        let openai = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"result"}]}]}"#.utf8)
        XCTAssertEqual(try TranslationService.extractText(openai, provider: .openAI), "result")
        let claude = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"result"}]}"#.utf8)
        XCTAssertEqual(try TranslationService.extractText(claude, provider: .claude), "result")
        XCTAssertThrowsError(try TranslationService.extractText(Data(#"{"status":"incomplete"}"#.utf8), provider: .openAI))
        XCTAssertThrowsError(try TranslationService.extractText(Data(#"{"stop_reason":"max_tokens"}"#.utf8), provider: .claude))
    }
}
