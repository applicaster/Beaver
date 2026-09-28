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
        #expect(link {
            $0.template = .present; $0.feedURL = "https://f.io/a.json"; $0.id = "urn:item/7"
        }.url == "myapp://present?data_source=aHR0cHM6Ly9mLmlvL2EuanNvbg%3D%3D&entry_id=dXJuOml0ZW0vNw%3D%3D")
        // Web has no Present: Screen Type instead.
        #expect(link { $0.mode = .web; $0.template = .present; $0.screenType = "movie" }.url
                == "https://app.example.com/index.html?type=movie")
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
        #expect(copied.summary == "Link: myapp://open?type=movie. Copied to the clipboard")
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
