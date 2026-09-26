import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct DiscoveredConsole: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let type: String
  public let address: String
  public let isAwake: Bool

  public init(id: String, name: String, type: String, address: String, isAwake: Bool) {
    self.id = id
    self.name = name
    self.type = type
    self.address = address
    self.isAwake = isAwake
  }
}

public enum ConsoleDiscovery {
  private static let requests: [(port: UInt16, version: String)] = [
    (987, "00020020"),
    (9302, "00030010"),
  ]

  public static func search(timeout: TimeInterval = 3) async -> [DiscoveredConsole] {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: searchSynchronously(timeout: timeout))
      }
    }
  }

  public static func parseResponse(_ data: Data, senderAddress: String) -> DiscoveredConsole? {
    guard let response = String(data: data, encoding: .utf8) else { return nil }
    let lines = response.split(whereSeparator: \.isNewline).map(String.init)
    guard let statusLine = lines.first else { return nil }
    let statusParts = statusLine.split(separator: " ", maxSplits: 2)
    guard statusParts.count >= 2,
      statusParts[0].hasPrefix("HTTP/"),
      let statusCode = Int(statusParts[1])
    else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    guard let hostID = headers["host-id"] else { return nil }
    let type = headers["host-type"] ?? "PlayStation"
    return DiscoveredConsole(
      id: hostID,
      name: headers["host-name"] ?? type,
      type: type,
      address: senderAddress,
      isAwake: statusCode == 200
    )
  }

  private static func searchSynchronously(timeout: TimeInterval) -> [DiscoveredConsole] {
    #if canImport(Darwin) || canImport(Glibc)
      #if canImport(Glibc)
        let descriptor = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
      #else
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
      #endif
      guard descriptor >= 0 else { return [] }
      defer { close(descriptor) }

      var enabled: Int32 = 1
      guard
        setsockopt(
          descriptor, SOL_SOCKET, SO_BROADCAST, &enabled,
          socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
      else {
        return []
      }

      for request in requests {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = request.port.bigEndian
        destination.sin_addr = in_addr(s_addr: inet_addr("255.255.255.255"))
        let payload = Data(
          "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(request.version)\n".utf8)
        withUnsafePointer(to: &destination) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            payload.withUnsafeBytes { bytes in
              _ = sendto(
                descriptor, bytes.baseAddress, bytes.count, 0, socketAddress,
                socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
        }
      }

      var consoles: [String: DiscoveredConsole] = [:]
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pollDescriptor, 1, 200) > 0 else { continue }

        var sender = sockaddr_in()
        var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        var buffer = [UInt8](repeating: 0, count: 2048)
        let received = withUnsafeMutablePointer(to: &sender) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            recvfrom(descriptor, &buffer, buffer.count, 0, socketAddress, &senderLength)
          }
        }
        guard received > 0 else { continue }
        var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var senderAddress = sender.sin_addr
        guard
          inet_ntop(AF_INET, &senderAddress, &addressBuffer, socklen_t(addressBuffer.count)) != nil
        else { continue }
        let addressBytes = addressBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let address = String(decoding: addressBytes, as: UTF8.self)
        if let console = parseResponse(Data(buffer.prefix(received)), senderAddress: address) {
          consoles[console.id] = console
        }
      }
      return consoles.values.filter(\.isAwake).sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    #else
      return []
    #endif
  }
}
