import XCTest
@testable import ReverseOfPowerCore

final class GameProtocolTests: XCTestCase {
    func testConnectionRequestMatchesWireFormat() {
        let data = GameProtocolCodec.connectionRequest()
        XCTAssertEqual(data.count, 38)
        XCTAssertEqual(Array(data.prefix(6)), [0x8a, 0x33, 0xff, 0xff, 0xff, 0xff])
    }

    func testJSONRoundTripPacket() throws {
        let packets = try GameProtocolCodec.encodeJSON(["TypeString": "Test", "value": 42], messageID: 7)
        XCTAssertEqual(packets.count, 1)
        let decoded = try GameProtocolCodec.decodePacket(packets[0])
        XCTAssertEqual(decoded.messageID, 7)
        XCTAssertEqual(decoded.packetIndex, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded.payload.dropFirst(10)) as? [String: Any])
        XCTAssertEqual(object["TypeString"] as? String, "Test")
        XCTAssertEqual(object["value"] as? Int, 42)
    }

    func testLargeMessageIsFragmented() throws {
        let packets = try GameProtocolCodec.encodeJSON(["value": String(repeating: "x", count: 2200)], messageID: 9)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(try GameProtocolCodec.decodePacket(packets[2]).packetIndex, 2)
    }
}
