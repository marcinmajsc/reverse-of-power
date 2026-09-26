import Foundation

public enum GameProtocolError: Error, Equatable {
  case packetTooShort
  case invalidMagic
  case invalidLength
}

public struct GamePacket: Equatable, Sendable {
  public let messageID: Int32
  public let packetCount: Int32
  public let packetIndex: Int32
  public let offset: Int32
  public let payload: Data
}

public enum GameProtocolCodec {
  public static let maximumPayload = 1002

  public static func connectionRequest() -> Data {
    Data([0x8a, 0x33, 0xff, 0xff, 0xff, 0xff] + Array(repeating: 0, count: 32))
  }

  public static func deviceUID(_ uid: String, decades: Bool = false) -> Data {
    let uidData = Data(uid.utf8)
    var result = Data(
      decades
        ? [0xaf, 0xe4, 0x87, 0x3d, 0x82, 0xed, 0x6c, 0x47]
        : [0x0c, 0x89, 0xe8, 0x84, 0x61, 0x03, 0xf4, 0x63]
    )
    result.appendLE(Int32(uidData.count))
    result.append(uidData)
    return result
  }

  public static func acknowledgement(messageID: Int32) -> Data {
    var result = Data([0x8a, 0x33])
    result.appendLE(messageID)
    result.append(Data(repeating: 0, count: 32))
    return result
  }

  public static func isConnectionAcknowledgement(_ data: Data) -> Bool {
    data.count == 38 && data.starts(with: [0x8a, 0x33, 0xff, 0xff, 0xff, 0xff])
  }

  public static func decodeJSONPayload(_ payload: Data) -> [String: Any]? {
    guard payload.count >= 10,
      payload[0] == 0x33,
      payload[1] == 0x29,
      payload.int32LE(at: 2) == Int32(bitPattern: 0xffff_e2b1)
    else { return nil }
    let length = Int(payload.int32LE(at: 6))
    guard length >= 0, payload.count == 10 + length else { return nil }
    return try? JSONSerialization.jsonObject(with: payload.dropFirst(10)) as? [String: Any]
  }

  public static func encodeJSON(_ object: [String: Any], messageID: Int32) throws -> [Data] {
    let json = try JSONSerialization.data(withJSONObject: object)
    var body = Data([0x33, 0x29])
    body.appendLE(Int32(bitPattern: 0xffff_e2b1))
    body.appendLE(Int32(json.count))
    body.append(json)
    return stride(from: 0, to: body.count, by: maximumPayload).enumerated().map { index, offset in
      let end = min(offset + maximumPayload, body.count)
      let chunk = body[offset..<end]
      var packet = Data([0xae, 0x7f])
      packet.appendLE(messageID)
      packet.appendLE(Int32((body.count + maximumPayload - 1) / maximumPayload))
      packet.appendLE(Int32(index))
      packet.appendLE(Int32(chunk.count))
      packet.appendLE(Int32(offset))
      packet.append(chunk)
      return packet
    }
  }

  public static func decodePacket(_ data: Data) throws -> GamePacket {
    guard data.count >= 22 else { throw GameProtocolError.packetTooShort }
    guard data[0] == 0xae, data[1] == 0x7f else { throw GameProtocolError.invalidMagic }
    let length = Int(data.int32LE(at: 14))
    guard length >= 0, data.count == 22 + length else { throw GameProtocolError.invalidLength }
    return GamePacket(
      messageID: data.int32LE(at: 2), packetCount: data.int32LE(at: 6),
      packetIndex: data.int32LE(at: 10), offset: data.int32LE(at: 18),
      payload: data.subdata(in: 22..<data.count))
  }
}

extension Data {
  mutating func appendLE(_ value: Int32) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }

  func int32LE(at offset: Int) -> Int32 {
    let value = self[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
      $0 | (UInt32($1.element) << UInt32($1.offset * 8))
    }
    return Int32(bitPattern: value)
  }
}
