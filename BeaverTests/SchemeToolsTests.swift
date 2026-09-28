import Testing
import CoreImage
import Foundation
@testable import BeaverCore

@Suite("Scheme Generator")
struct SchemeToolsTests {

    private func link(_ change: (inout SchemeLink) -> Void) -> SchemeLink {
        var l = SchemeLink()
        change(&l)
        return l
    }

    /// Expected URLs come from zapp-support's generator
    /// (xraySchemeGenerator.ts: URLSearchParams + btoa), run in Node.
    @Test("Same URL as zapp-support for every template")
    func urls() {
        #expect(SchemeLink().url == "myapp://open")
        #expect(link {
            $0.screenType = "movie"; $0.id = "a b/c*~"; $0.state = .fullscreen; $0.title = "My Screen & more"
        }.url == "myapp://open?type=movie&id=a+b%2Fc*%7E&state=fullscreen&title=My+Screen+%26+more")
        #expect(link {
            $0.mode = .web; $0.template = .feedContent
            $0.feedURL = "https://feeds.example.com/movies.json?x=1"; $0.position = "3"
        }.url == "https://app.example.com/index.html?feed_locator=https%3A%2F%2Ffeeds.example.com%2Fmovies.json%3Fx%3D1&position=3")
        #expect(link {
            $0.template = .feedContent; $0.feedURL = "https://f.io/a.json"; $0.id = "42"; $0.position = "3"
        }.url == "myapp://open?feed_locator=https%3A%2F%2Ff.io%2Fa.json&id=42")
        #expect(link {
            $0.template = .directScreen; $0.screenId = "MOVIE_SCREEN"; $0.state = .inline
        }.url == "myapp://open?screen_id=MOVIE_SCREEN&state=inline")
        #expect(link {
            $0.template = .present; $0.feedURL = "https://feeds.example.com/movies.json"
            $0.screenId = "MOVIE_SCREEN"; $0.id = "abc-123_.~"; $0.title = "ignored"
        }.url == "myapp://present?data_source=aHR0cHM6Ly9mZWVkcy5leGFtcGxlLmNvbS9tb3ZpZXMuanNvbg%3D%3D&screen_id=MOVIE_SCREEN&entry_id=abc-123_.%7E")
        // Deliberately not zapp-support's: QuickBrick matches entry_id as
        // sent, so it isn't base64-encoded (zapp-support gives dXJuOml0ZW0vNw%3D%3D).
        #expect(link {
            $0.template = .present; $0.feedURL = "https://f.io/a.json"; $0.id = "urn:item/7"; $0.resumeTime = "90"
        }.url == "myapp://present?data_source=aHR0cHM6Ly9mLmlvL2EuanNvbg%3D%3D&entry_id=urn%3Aitem%2F7&resumeTime=90")
        // Web has no Present: Screen Type instead.
        #expect(link { $0.mode = .web; $0.template = .present; $0.screenType = "movie" }.url
                == "https://app.example.com/index.html?type=movie")
    }

    @Test("Every host the apps handle: present, web page, layout, X-Ray, native actions, custom")
    func hosts() {
        #expect(link { $0.template = .present; $0.screenId = "HOME"; $0.pushScreen = true }.url
                == "myapp://present?screen_id=HOME&isInternalLink=true")
        #expect(link {
            $0.template = .webPage; $0.linkURL = "https://x.io/help?a=1"; $0.showNavBar = true; $0.contentType = "link"
        }.url == "myapp://present?link_url=https%3A%2F%2Fx.io%2Fhelp%3Fa%3D1&content_type=link&show_nav_bar=true")
        #expect(link { $0.template = .layout; $0.layoutId = "abc-1" }.url == "myapp://present?rivers_configuration_id=abc-1")
        #expect(link { $0.mode = .web; $0.template = .layout; $0.layoutId = "abc-1" }.url
                == "https://app.example.com/index.html?rivers_configuration_id=abc-1")
        #expect(link { $0.template = .xray }.url == "myapp://xray")
        #expect(link { $0.template = .xray; $0.xrayAction = .connect; $0.xrayValue = "ws://10.0.0.2:9080" }.url
                == "myapp://xray?remoteAssistance=ws%3A%2F%2F10.0.0.2%3A9080")
        #expect(link { $0.template = .xray; $0.xrayAction = .pin; $0.xrayValue = "1234" }.url == "myapp://xray?pin_code=1234")
        #expect(link { $0.template = .xray; $0.xrayAction = .exportLogs }.url == "myapp://xray/exportLogs")
        #expect(link {
            $0.template = .xray; $0.xrayAction = .shareLog; $0.fileLogLevel = "debug"; $0.floatingButton = true; $0.mcpServer = false
        }.url == "myapp://xray?shareLog=true&fileLogLevel=debug&showXrayFloatingButtonEnabled=true&mcpServerEnabled=false")
        #expect(link { $0.template = .resetUUID }.url == "myapp://generateNewUUID")
        #expect(link { $0.template = .externalAccount }.url == "myapp://externalLinkAccount")
        #expect(link { $0.template = .custom; $0.host = "plugin"; $0.extras = "pluginIdentifier=opta\naction = show" }.url
                == "myapp://plugin?pluginIdentifier=opta&action=show")
        // open passes extra params on; state and title belong to open only.
        #expect(link { $0.screenType = "movie"; $0.extras = "season=2&x y=a b" }.url == "myapp://open?type=movie&season=2&x+y=a+b")
        #expect(link { $0.template = .layout; $0.layoutId = "a"; $0.state = .inline; $0.title = "T" }.url
                == "myapp://present?rivers_configuration_id=a")
        // Web has no Present / X-Ray: Screen Type instead.
        #expect(link { $0.mode = .web; $0.template = .xray; $0.screenType = "movie" }.url
                == "https://app.example.com/index.html?type=movie")
    }

    @Test("scheme_build: templates follow the keys; X-Ray connect defaults to this Beaver")
    func buildTemplates() async throws {
        let (ctx, _) = makeUIContext(try LogStore(source: .inMemory))
        func url(_ args: [String: JSON]) async throws -> String? {
            try await SchemeTools.build.run(ToolArguments(["scheme": "app"].merging(args) { $1 }), ctx).structured["url"]?.string
        }
        #expect(try await url(["xrayAction": "connect"]) == "app://xray?remoteAssistance=ws%3A%2F%2F192.168.1.5%3A9080")
        #expect(try await url(["pinCode": 4321]) == "app://xray?pin_code=4321")
        #expect(try await url(["linkUrl": "https://x.io"]) == "app://present?link_url=https%3A%2F%2Fx.io")
        #expect(try await url(["layoutId": "L1"]) == "app://present?rivers_configuration_id=L1")
        #expect(try await url(["host": "plugin", "params": ["pluginIdentifier": "opta", "id": 7]])
                == "app://plugin?id=7&pluginIdentifier=opta")
        #expect(try await url(["template": "generateNewUUID"]) == "app://generateNewUUID")
        #expect(try await url(["screenType": "movie", "params": "season=2"]) == "app://open?type=movie&season=2")
        for bad: [String: JSON] in [["template": "web-page"], ["template": "layout"], ["template": "custom"],
                                    ["pinCode": 0], ["fileLogLevel": "loud"], ["xrayAction": "dance"],
                                    ["mode": "web", "template": "xray"], ["params": 5]] {
            await #expect(throws: ToolError.self) { try await url(bad) }
        }
        let empty = try await SchemeTools.build.run(ToolArguments(["scheme": "app"]), ctx)
        #expect(empty.summary.contains("open needs type, screen_id or feed_locator"))
    }

    @Test("The QR code PNG scans back to the link")
    func qr() throws {
        let url = "myapp://open?type=movie&id=42"
        let png = try #require(SchemeLink.qrPNG(url))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let image = try #require(CIImage(data: png))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil))
        let found = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(found == [url])
    }

    @Test("scheme_build returns the link and leaves the window alone")
    func build() async throws {
        let (ctx, fake) = makeUIContext(try LogStore(source: .inMemory))
        let r = try await SchemeTools.build.run(ToolArguments([
            "scheme": "zapp://", "template": "Direct Screen", "screenId": "HOME", "state": "none",
        ]), ctx)
        #expect(r.summary == "Link: zapp://open?screen_id=HOME")
        #expect(r.structured["url"] == "zapp://open?screen_id=HOME")
        #expect(r.structured["template"] == "direct-screen")
        #expect(fake.changes.isEmpty)
        #expect(fake.copied.isEmpty)
        #expect(r.structured["copied"] == false)

        let copied = try await SchemeTools.build.run(ToolArguments(["screenType": "movie", "copy": true]), ctx)
        #expect(fake.copied == ["myapp://open?type=movie"])
        #expect(copied.summary.hasPrefix("Link: myapp://open?type=movie (myapp is a placeholder: no session"))
        #expect(copied.summary.hasSuffix(". Copied to the clipboard"))
        #expect(fake.changes.isEmpty)
    }

    @Test("show edits the form on screen; reset starts empty; reveal is passed on")
    func show() async throws {
        var ui = UIState()
        ui.scheme.scheme = "acme"
        ui.scheme.screenType = "movie"
        let (ctx, fake) = makeUIContext(try LogStore(source: .inMemory), ui: HostSnapshot(ui: ui))
        let r = try await SchemeTools.build.run(ToolArguments(["show": true, "id": 42]), ctx)
        #expect(r.summary.hasPrefix("Filled the Scheme Generator in the background"))
        #expect(fake.value.ui.tab == .schemes)
        #expect(fake.value.ui.scheme.url == "acme://open?type=movie&id=42")
        #expect(fake.changes.last?.reveal == false)

        _ = try await SchemeTools.build.run(ToolArguments(["reveal": true, "reset": true, "screenType": "show"]), ctx)
        #expect(fake.value.ui.scheme.url == "myapp://open?type=show")
        #expect(fake.changes.last?.reveal == true)

        // The form survives a session switch.
        let switched = fake.value.ui.applying(UIChange(sessionId: 7))
        #expect(switched.scheme == fake.value.ui.scheme)

        let state = try await UITools.state.run(ToolArguments(), ctx)
        #expect(state.summary.hasPrefix("Beaver shows Scheme Generator — myapp://open?type=show"))
        #expect(state.structured["scheme"]?["url"] == "myapp://open?type=show")
    }

    @Test("Bad input fails with an example; ui_show knows the tab")
    func errors() async throws {
        let (ctx, fake) = makeUIContext(try LogStore(source: .inMemory))
        for args: [String: JSON] in [["mode": "web", "template": "present"], ["position": "-1"],
                                     ["template": "nope"], ["state": "hidden"], ["scheme": "://"]] {
            await #expect(throws: ToolError.self) { try await SchemeTools.build.run(ToolArguments(args), ctx) }
        }
        do {
            _ = try await SchemeTools.build.run(ToolArguments(["mode": "web", "template": "present"]), ctx)
        } catch let error as ToolError {
            #expect(error.message.contains("Example: scheme_build("))
        }
        _ = try await UITools.show.run(ToolArguments(["tab": "scheme generator"]), ctx)
        #expect(fake.value.ui.tab == .schemes)
    }

    @Test("The app's scheme comes from the session's storage (applicaster.v2.urlScheme)")
    func schemeFromStorage() async throws {
        let store = try LogStore(source: .inMemory)
        let app = try await store.createSession(source: .live).id
        // What iOS sends: the array as a JSON string.
        try await store.recordStorageSnapshot(sessionId: app, namespace: .session,
                                              dataJSON: #"{"applicaster.v2":{"platform":"iOS","urlScheme":"[\"aio\",\"aio2\"]"}}"#)
        let bare = try await store.createSession(source: .imported).id
        try await store.recordStorageSnapshot(sessionId: bare, namespace: .local,
                                              dataJSON: #"{"applicaster.v2":{"platform":"iOS"}}"#)
        let (ctx, _) = makeUIContext(store, ui: HostSnapshot(viewingSessionId: app))

        let r = try await SchemeTools.build.run(ToolArguments(["screenType": "movie"]), ctx)
        #expect(r.structured["url"] == "aio://open?type=movie")
        #expect(r.structured["schemeFromSessionId"]?.int64 == app)
        #expect(r.summary.contains("scheme aio from session #\(app)"))
        #expect(r.summary.contains("(also aio2)"))

        let given = try await SchemeTools.build.run(ToolArguments(["scheme": "other", "screenType": "movie"]), ctx)
        #expect(given.structured["url"] == "other://open?type=movie")
        #expect(given.structured["schemeFromSessionId"] == .null)

        let none = try await SchemeTools.build.run(ToolArguments(["sessionId": .number(Double(bare))]), ctx)
        #expect(none.structured["url"] == "myapp://open")
        #expect(none.summary.contains("storage has no applicaster.v2.urlScheme, pass scheme"))
        let empty = try await store.createSession(source: .imported).id
        let noStorage = try await SchemeTools.build.run(ToolArguments(["sessionId": .number(Double(empty))]), ctx)
        #expect(noStorage.summary.contains("has no storage yet"))

        await #expect(throws: ToolError.self) {
            try await SchemeTools.build.run(ToolArguments(["sessionId": 999]), ctx)
        }
    }

    @Test("urlScheme as a JSON string, an array, a plain string, or missing")
    func urlSchemeForms() {
        #expect(SchemeLink.urlSchemes(inSnapshot: #"{"applicaster.v2":{"urlScheme":"[\"miami\"]"}}"#) == ["miami"])
        #expect(SchemeLink.urlSchemes(inSnapshot: #"{"applicaster.v2":{"urlScheme":["gw","x"]}}"#) == ["gw", "x"])
        #expect(SchemeLink.urlSchemes(inSnapshot: #"{"applicaster.v2":{"urlScheme":"vbtv://"}}"#) == ["vbtv"])
        #expect(SchemeLink.urlSchemes(inSnapshot: #"{"applicaster.v2":"{\"urlScheme\":\"[\\\"yes\\\"]\"}"}"#) == ["yes"])
        #expect(SchemeLink.urlSchemes(inSnapshot: #"{"applicaster.v2":{"platform":"iOS"}}"#).isEmpty)
        #expect(SchemeLink.urlSchemes(inSnapshot: "not json").isEmpty)
    }

    @Test("qrFile writes a PNG and won't replace a file without overwrite")
    func qrFile() async throws {
        let (ctx, _) = makeUIContext(try LogStore(source: .inMemory))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("beaver-qr-\(UUID()).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = try await SchemeTools.build.run(ToolArguments(["screenType": "movie", "qrFile": .string(path)]), ctx)
        #expect(r.structured["qrFile"] == .string(path))
        #expect(FileManager.default.fileExists(atPath: path))
        await #expect(throws: ToolError.self) {
            try await SchemeTools.build.run(ToolArguments(["qrFile": .string(path)]), ctx)
        }
        _ = try await SchemeTools.build.run(ToolArguments(["qrFile": .string(path), "overwrite": true]), ctx)
    }
}
