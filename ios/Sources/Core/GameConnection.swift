import Foundation
#if canImport(Network)
import Combine
import Network
import UIKit

@MainActor
public final class GameConnection: ObservableObject {
    @Published public private(set) var isConnected = false
    @Published public private(set) var lastMessage: [String: Any] = [:]
    @Published public private(set) var errorMessage: String?
    private var connection: NWConnection?
    private var messageID: Int32 = 1
    private let queue = DispatchQueue(label: "reverse-of-power.udp")

    public init() {}

    public func connect(host: String, port: UInt16 = 9066) {
        disconnect()
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state {
                    self.isConnected = true
                    self.sendRaw(GameProtocolCodec.connectionRequest())
                    let uid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
                    self.sendRaw(GameProtocolCodec.deviceUID(uid))
                    self.sendRaw(GameProtocolCodec.deviceUID(uid, decades: true))
                    self.receive()
                } else if case let .failed(error) = state {
                    self.errorMessage = error.localizedDescription
                    self.isConnected = false
                }
            }
        }
        connection.start(queue: queue)
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    public func send(type: String, fields: [String: Any] = [:]) {
        var value = fields
        value["TypeString"] = type
        do {
            for packet in try GameProtocolCodec.encodeJSON(value, messageID: messageID) { sendRaw(packet) }
            messageID &+= 1
        } catch { errorMessage = error.localizedDescription }
    }

    private func sendRaw(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, let packet = try? GameProtocolCodec.decodePacket(data) {
                self.sendRaw(GameProtocolCodec.acknowledgement(messageID: packet.messageID))
                if packet.packetCount == 1, packet.payload.count >= 10 {
                    let json = packet.payload.dropFirst(10)
                    if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
                        Task { @MainActor in self.lastMessage = object }
                    }
                }
            }
            self.receive()
        }
    }
}
#endif
