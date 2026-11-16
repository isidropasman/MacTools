import Foundation
import Network

@MainActor
final class BrowserMediaServer {
    nonisolated static let port: UInt16 = 7718
    nonisolated static let subprotocolName = "notchbox-media-v1"

    private struct Message: Decodable {
        enum Kind: String, Decodable { case state, gone, ping }
        let kind: Kind
        let tabID: Int?
        let media: BrowserMediaStore.Snapshot?
    }

    private let store: BrowserMediaStore
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    init(store: BrowserMediaStore) {
        self.store = store
        store.onCommand = { [weak self] target, command in self?.send(command, to: target.clientID) }
    }

    func start(port: UInt16 = BrowserMediaServer.port) {
        guard self.listener == nil else { return }
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = 64 * 1024
        webSocket.setClientRequestHandler(.main) { protocols, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            let accepted = protocols.contains(Self.subprotocolName) && Self.accepts(origin: origin)
            return NWProtocolWebSocket.Response(
                status: accepted ? .accept : .reject,
                subprotocol: accepted ? Self.subprotocolName : nil
            )
        }
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        guard let listener = try? NWListener(using: parameters) else {
            NSLog("Notchbox: no se pudo iniciar el puente de medios del navegador")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }
        self.listener = listener
        self.store.start()
        listener.start(queue: .main)
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
        let connections = self.connections
        self.connections.removeAll()
        for (id, connection) in connections {
            connection.cancel()
            self.store.remove(clientID: id)
        }
    }

    nonisolated static func accepts(origin: String?) -> Bool {
        guard let origin, let url = URL(string: origin), url.scheme == "chrome-extension",
              let host = url.host, host.utf8.count == 32,
              host.utf8.allSatisfy({ (97...112).contains($0) }),
              url.user == nil, url.password == nil, url.port == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil
        else { return false }
        return true
    }

    private func accept(_ connection: NWConnection) {
        guard self.connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        self.connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.receive(connection, id: id)
                case .failed, .cancelled: self?.disconnect(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func disconnect(_ id: UUID) {
        self.connections.removeValue(forKey: id)?.cancel()
        self.store.remove(clientID: id)
    }

    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, context, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                guard error == nil, metadata?.opcode != .close else { self.disconnect(id); return }
                if let data, metadata?.opcode == .text, complete, data.count <= 64 * 1024,
                   let message = try? JSONDecoder().decode(Message.self, from: data) {
                    switch message.kind {
                    case .state:
                        if let tabID = message.tabID, let snapshot = message.media {
                            self.store.receive(snapshot, clientID: id, tabID: tabID)
                        }
                    case .gone:
                        if let tabID = message.tabID { self.store.remove(clientID: id, tabID: tabID) }
                    case .ping: break
                    }
                }
                self.receive(connection, id: id)
            }
        }
    }

    private func send(_ command: BrowserMediaStore.Command, to clientID: UUID) {
        guard let connection = self.connections[clientID],
              let data = try? JSONEncoder().encode(command)
        else { return }
        let context = NWConnection.ContentContext(
            identifier: command.id.uuidString,
            metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.disconnect(clientID) }
        })
    }
}
