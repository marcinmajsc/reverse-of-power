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
    private var listener: NWListener?
    private var inboundConnections: [ObjectIdentifier: NWConnection] = [:]
    private var handshakeTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var outgoingReady = false
    private var listenerReady = false
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

      let listener: NWListener
      do {
        let listenerParameters = NWParameters.udp
        listenerParameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: listenerParameters, on: localPort)
      } catch {
        errorMessage = "Nie można nasłuchiwać na porcie 9060: \(error.localizedDescription)"
        return
      }

      // PlayLink does not reply to the UDP source port. It sends all game traffic
      // to the controller's fixed port 9060, sometimes from a port other than
      // 9066. A separate listener is therefore required; a connected UDP socket
      // silently filters those packets on iOS.
      self.listener = listener
      listener.stateUpdateHandler = { [weak self, weak listener] state in
        Task { @MainActor in
          guard let self, listener === self.listener else { return }
          switch state {
          case .ready:
            self.listenerReady = true
            self.errorMessage = nil
            self.startHandshakeIfReady()
          case .waiting(let error):
            self.errorMessage =
              "Oczekiwanie na dostęp do sieci lokalnej: \(error.localizedDescription)"
          case .failed(let error):
            self.failConnection(error.localizedDescription)
          case .cancelled:
            self.listenerReady = false
          default:
            break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] inbound in
        Task { @MainActor [weak self] in
          guard let self, self.listener != nil else {
            inbound.cancel()
            return
          }
          self.inboundConnections[ObjectIdentifier(inbound)] = inbound
          inbound.start(queue: self.queue)
          self.receive(on: inbound)
        }
      }
      listener.start(queue: queue)

      let parameters = NWParameters.udp
      let connection = NWConnection(
        host: NWEndpoint.Host(address), port: remotePort, using: parameters)
      self.connection = connection
      isConnecting = true
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        Task { @MainActor in
          guard let self, let connection, connection === self.connection else { return }
          switch state {
          case .ready:
            self.outgoingReady = true
            self.errorMessage = nil
            self.receive(on: connection)
            self.startHandshakeIfReady()
          case .waiting(let error):
            // The first local-network access prompt temporarily puts an
            // NWConnection into .waiting. Keep it alive so accepting the prompt
            // can move the same connection to .ready.
            self.errorMessage =
              "Oczekiwanie na dostęp do sieci lokalnej: \(error.localizedDescription)"
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
      readinessTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self, self.isConnecting,
          !self.outgoingReady || !self.listenerReady
        else { return }
        self.failConnection("Nie można uzyskać dostępu do sieci lokalnej.")
      }
    }

    public func disconnect() {
      readinessTask?.cancel()
      readinessTask = nil
      handshakeTask?.cancel()
      handshakeTask = nil
      connection?.stateUpdateHandler = nil
      connection?.cancel()
      connection = nil
      listener?.stateUpdateHandler = nil
      listener?.newConnectionHandler = nil
      listener?.cancel()
      listener = nil
      for inboundConnection in inboundConnections.values {
        inboundConnection.cancel()
      }
      inboundConnections.removeAll()
      outgoingReady = false
      listenerReady = false
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

    private func startHandshakeIfReady() {
      guard outgoingReady, listenerReady, handshakeTask == nil else { return }
      readinessTask?.cancel()
      readinessTask = nil
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

    private func receive(on receivingConnection: NWConnection) {
      receivingConnection.receiveMessage {
        [weak self, weak receivingConnection] data, _, _, error in
        Task { @MainActor [weak self] in
          guard let self, let receivingConnection else { return }
          if let error {
            if receivingConnection === self.connection {
              self.failConnection(error.localizedDescription)
            } else {
              self.inboundConnections.removeValue(forKey: ObjectIdentifier(receivingConnection))
              receivingConnection.cancel()
            }
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
          if receivingConnection === self.connection
            || self.inboundConnections[ObjectIdentifier(receivingConnection)] != nil
          {
            self.receive(on: receivingConnection)
          }
        }
      }
    }
  }
#endif
