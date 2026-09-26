import XCTest

@testable import ReverseOfPowerCore

final class GameProtocolTests: XCTestCase {
  func testConnectionRequestMatchesWireFormat() {
    let data = GameProtocolCodec.connectionRequest()
    XCTAssertEqual(data.count, 38)
    XCTAssertEqual(Array(data.prefix(6)), [0x8a, 0x33, 0xff, 0xff, 0xff, 0xff])
  }

  func testJSONRoundTripPacket() throws {
    let packets = try GameProtocolCodec.encodeJSON(
      ["TypeString": "Test", "value": 42], messageID: 7)
    XCTAssertEqual(packets.count, 1)
    let decoded = try GameProtocolCodec.decodePacket(packets[0])
    XCTAssertEqual(decoded.messageID, 7)
    XCTAssertEqual(decoded.packetIndex, 0)
    let object = try XCTUnwrap(GameProtocolCodec.decodeJSONPayload(decoded.payload))
    XCTAssertEqual(object["TypeString"] as? String, "Test")
    XCTAssertEqual(object["value"] as? Int, 42)
  }

  func testLargeMessageIsFragmented() throws {
    let packets = try GameProtocolCodec.encodeJSON(
      ["value": String(repeating: "x", count: 2200)], messageID: 9)
    XCTAssertEqual(packets.count, 3)
    XCTAssertEqual(try GameProtocolCodec.decodePacket(packets[2]).packetIndex, 2)
  }
}

extension GameProtocolTests {
  func testConnectionAcknowledgementRecognition() {
    XCTAssertTrue(
      GameProtocolCodec.isConnectionAcknowledgement(GameProtocolCodec.connectionRequest()))
    XCTAssertFalse(
      GameProtocolCodec.isConnectionAcknowledgement(GameProtocolCodec.acknowledgement(messageID: 1))
    )
  }

  func testDiscoveryResponseParsing() throws {
    let response = Data(
      """
      HTTP/1.1 200 Ok
      host-id:001122334455
      host-type:PS4
      host-name:Salon

      """.utf8)
    let console = try XCTUnwrap(
      ConsoleDiscovery.parseResponse(response, senderAddress: "192.168.1.50"))
    XCTAssertEqual(console.id, "001122334455")
    XCTAssertEqual(console.name, "Salon")
    XCTAssertEqual(console.type, "PS4")
    XCTAssertEqual(console.address, "192.168.1.50")
    XCTAssertTrue(console.isAwake)
  }

  func testDiscoveryIgnoresMalformedResponse() {
    XCTAssertNil(
      ConsoleDiscovery.parseResponse(Data("not DDP".utf8), senderAddress: "192.168.1.50"))
  }
}
