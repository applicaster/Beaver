import Testing
import Foundation
@testable import BeaverCore

/// The tree model is shared by the log detail pane and the storage
/// inspector, and its serializer backs every "copy as JSON" action — so
/// a round trip has to come back unchanged.
@Suite("StorageRecord")
struct StorageRecordTests {

    /// Serialize a parsed record and read it back as a plain Foundation
    /// object, so the comparison is about structure rather than spacing.
    private func asDictionary(_ json: String) throws -> NSDictionary {
        let data = try #require(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? NSDictionary)
    }

    private func roundTrip(_ json: String) throws -> NSDictionary {
        let record = try #require(StorageRecord.parse(json))
        return try asDictionary(StorageRecord.serializeJSON(record))
    }

    @Test("A document survives parse → serialize unchanged")
    func roundTripPreservesStructure() throws {
        let json = """
        {"name":"beaver","count":3,"ok":true,"missing":null,\
        "nested":{"a":[1,2,{"b":"c"}]},"quotes":"he said \\"hi\\"\\\\"}
        """
        let original = try asDictionary(json)
        let result = try roundTrip(json)

        #expect(result == original)
    }

    @Test("Empty containers stay containers")
    func emptyContainersSerializeAsThemselves() throws {
        let result = try roundTrip(#"{"obj":{},"arr":[]}"#)

        #expect(result["obj"] as? NSDictionary == NSDictionary())
        #expect((result["arr"] as? NSArray)?.count == 0)
    }

    @Test("An object key that looks like an array index stays an object key")
    func arrayLikeKeyDoesNotBecomeAnArray() throws {
        // Guards the old serializer, which decided array-vs-object by
        // checking whether every child key was shaped like `[0]`.
        let result = try roundTrip(#"{"weird":{"[0]":"x"}}"#)

        let weird = try #require(result["weird"] as? NSDictionary)
        #expect(weird["[0]"] as? String == "x")
    }
}
