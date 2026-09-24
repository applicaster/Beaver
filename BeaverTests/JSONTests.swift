import Testing
import Foundation
@testable import BeaverCore

@Suite("JSON")
struct JSONTests {
    @Test("Round-trips every kind of value")
    func roundTrip() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d/e"}}"#
        let value = try JSON.parse(Data(text.utf8))
        #expect(value.text == text)
    }

    @Test("Whole numbers encode without a fraction")
    func integers() {
        let value: JSON = ["id": 48211, "ratio": 0.5]
        #expect(value.text == #"{"id":48211,"ratio":0.5}"#)
    }

    @Test("Accessors")
    func accessors() throws {
        let value = try JSON.parse(Data(#"{"n":7,"s":"hi","b":false,"l":[1]}"#.utf8))
        #expect(value["n"]?.int == 7)
        #expect(value["n"]?.int64 == 7)
        #expect(value["s"]?.string == "hi")
        #expect(value["b"]?.bool == false)
        #expect(value["l"]?.array?.count == 1)
        #expect(value["missing"] == nil)
        #expect(JSON.number(2.5).int == nil)
    }

    @Test("Optional initialisers map nil to null")
    func optionals() {
        let none: String? = nil
        let noId: Int64? = nil
        #expect(JSON(none) == .null)
        #expect(JSON(noId) == .null)
        #expect(JSON(Int64(3)) == .number(3))
    }

    @Test("Unicode and newlines survive")
    func unicode() throws {
        let value: JSON = ["m": "ошибка 🔥\nline 2"]
        #expect(try JSON.parse(value.data()) == value)
    }
}
