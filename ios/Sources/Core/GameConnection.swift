import Foundation

#if canImport(Network)
  import Combine
  import Network
  #if canImport(UIKit)
    import UIKit
  #endif

  @MainActor
  public final class GameConnection: ObservableObject {
    @Published public private(set) var isConnected = false
    @Published public private(set) var isConnecting = false
    @Published public private(set) var lastMessage: [String: Any] = [:]
    @Published public private(set) var errorMessage: String?
    private var connection: NWConnection?
    private var handshakeTask: Task<Void, Never>?
    private var messageID: Int32 = 1
    private let queue = DispatchQueue(label: "reverse-of-power.udp")

    public init() {}

    public func connect(host: String, port: UInt16 = 9066) {
      disconnect()
      errorMessage = nil

      let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !address.isEmpty else {
        errorMessage = "Wpisz adres IP konsoli."
        return
      }
      guard let remotePort = NWEndpoint.Port(rawValue: port),
        let localPort = NWEndpoint.Port(rawValue: 9060)
      else {
        errorMessage = "Nieprawidłowy port połączenia."
        return
      }

      let parameters = NWParameters.udp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: localPort)
      let connection = NWConnection(
        host: NWEndpoint.Host(address), port: remotePort, using: parameters)
      self.connection = connection
      isConnecting = true
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        Task { @MainActor in
          guard let self, connection === self.connection else { return }
          switch state {
          case .ready:
            self.receive()
            self.startHandshake()
          case .waiting(let error):
            self.failConnection(
              "Nie można uzyskać dostępu do sieci lokalnej: \(error.localizedDescription)")
          case .failed(let error):
            self.failConnection(error.localizedDescription)
          case .cancelled:
            self.isConnecting = false
            self.isConnected = false
          default:
            break
          }
        }
      }
      connection.start(queue: queue)
    }

    public func disconnect() {
      handshakeTask?.cancel()
      handshakeTask = nil
      connection?.stateUpdateHandler = nil
      connection?.cancel()
      connection = nil
      isConnecting = false
      isConnected = false
    }

    public func send(type: String, fields: [String: Any] = [:]) {
      guard isConnected else {
        errorMessage = "Najpierw połącz aplikację z konsolą."
        return
      }
      var value = fields
      value["TypeString"] = type
      do {
        for packet in try GameProtocolCodec.encodeJSON(value, messageID: messageID) {
          sendRaw(packet)
        }
        messageID &+= 1
      } catch {
        errorMessage = error.localizedDescription
      }
    }

    private func startHandshake() {
      handshakeTask?.cancel()
      handshakeTask = Task { [weak self] in
        guard let self else { return }
        let uid = Self.deviceUID
        for _ in 0..<6 {
          guard !Task.isCancelled, self.isConnecting else { return }
          self.sendRaw(GameProtocolCodec.connectionRequest())
          self.sendRaw(GameProtocolCodec.deviceUID(uid))
          self.sendRaw(GameProtocolCodec.deviceUID(uid, decades: true))
          try? await Task.sleep(for: .seconds(1))
        }
        guard !Task.isCancelled, self.isConnecting else { return }
        self.failConnection("Konsola nie odpowiedziała. Sprawdź adres IP i sieć Wi‑Fi.")
      }
    }

    private func completeHandshake() {
      handshakeTask?.cancel()
      handshakeTask = nil
      errorMessage = nil
      isConnecting = false
      isConnected = true
    }

    private func failConnection(_ message: String) {
      disconnect()
      errorMessage = message
    }

    private func sendRaw(_ data: Data) {
      connection?.send(
        content: data,
        completion: .contentProcessed { [weak self] error in
          guard let error else { return }
          Task { @MainActor [weak self] in
            self?.failConnection(error.localizedDescription)
          }
        })
    }

    private static var deviceUID: String {
      #if canImport(UIKit)
        UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "")
          ?? UUID().uuidString
      #else
        UUID().uuidString
      #endif
    }

    private func receive() {
      connection?.receiveMessage { [weak self] data, _, _, error in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let error {
            self.failConnection(error.localizedDescription)
            return
          }
          if let data {
            if GameProtocolCodec.isConnectionAcknowledgement(data) {
              self.completeHandshake()
            } else if let packet = try? GameProtocolCodec.decodePacket(data) {
              self.completeHandshake()
              self.sendRaw(GameProtocolCodec.acknowledgement(messageID: packet.messageID))
              if packet.packetCount == 1,
                let object = GameProtocolCodec.decodeJSONPayload(packet.payload)
              {
                self.lastMessage = object
              }
            }
          }
          if self.connection != nil { self.receive() }
        }
      }
    }
  }
#endif
