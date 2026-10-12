import Combine
import Foundation
import Network

@MainActor
final class BrowserBridgeServer: ObservableObject {
    nonisolated static let extensionRequestToken = "inspiration-library-safari-extension-v1"
    enum Status: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    static let shared = BrowserBridgeServer()
    @Published private(set) var status: Status = .stopped
    private var listener: NWListener?
    private var listenerGeneration: UUID?
    private var retryTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.mooyumm.EagleReplica.browser-bridge")
    private let port: NWEndpoint.Port

    private init() {
        let configured = ProcessInfo.processInfo.environment["INSPIRATION_BRIDGE_PORT"].flatMap(UInt16.init) ?? 49158
        port = NWEndpoint.Port(rawValue: configured) ?? 49158
    }

    func start() {
        guard listener == nil else { return }
        status = .starting
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            let generation = UUID()
            listenerGeneration = generation
            listener.stateUpdateHandler = { [weak self] state in
                guard let server = self else { return }
                Task { @MainActor in
                    server.handleListenerState(state, generation: generation)
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                Self.receiveRequest(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            listener = nil
            listenerGeneration = nil
            status = .failed(error.localizedDescription)
            scheduleRetry()
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        listenerGeneration = nil
        listener?.cancel()
        listener = nil
        status = .stopped
    }

    var failureMessage: String? {
        guard case .failed = status else { return nil }
        return "网页采集暂不可用：端口 \(port.rawValue) 正被旧版占用。关闭旧版后会自动恢复。"
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            retryTask = nil
            if case .failed = status { start() }
        }
    }

    private func handleListenerState(_ state: NWListener.State, generation: UUID) {
        guard listenerGeneration == generation else { return }
        switch state {
        case .ready:
            retryTask?.cancel()
            retryTask = nil
            status = .ready
        case .failed(let error):
            status = .failed(error.localizedDescription)
            listenerGeneration = nil
            listener?.cancel()
            listener = nil
            scheduleRetry()
        case .cancelled:
            listenerGeneration = nil
            listener = nil
            status = .stopped
        default:
            break
        }
    }

    private nonisolated static func receiveRequest(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var request = buffer
            if let data { request.append(data) }
            let maximumRequestSize = 82 * 1024 * 1024
            if let declaredLength = contentLength(from: request), declaredLength > 80 * 1024 * 1024 {
                finish(connection, status: "413 Content Too Large")
                return
            }
            guard request.count <= maximumRequestSize else {
                finish(connection, status: "413 Content Too Large")
                return
            }
            if isCompleteRequest(request) {
                handleRequest(request, connection: connection)
            } else if error != nil || isComplete {
                finish(connection, status: "400 Bad Request")
            } else {
                receiveRequest(connection, buffer: request)
            }
        }
    }

    private nonisolated static func handleRequest(_ request: Data, connection: NWConnection) {
        if httpMethod(from: request) == "OPTIONS" {
            finish(connection, status: "204 No Content", body: Data())
            return
        }
        guard httpMethod(from: request) == "POST", let body = httpBody(from: request) else {
            finish(connection, status: "400 Bad Request")
            return
        }

        guard isTrustedExtensionRequest(request) else {
            finish(connection, status: "403 Forbidden")
            return
        }

        if httpPath(from: request) == "/payload" {
            guard let sessionID = headerValue("x-inspiration-session", from: request),
                  !sessionID.isEmpty,
                  sessionID.count <= 128,
                  !body.isEmpty,
                  body.count <= 80 * 1024 * 1024 else {
                finish(connection, status: "400 Bad Request")
                return
            }
            let mimeType = headerValue("x-inspiration-mime", from: request)
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    BrowserPayloadCache.shared.store(body, sessionID: sessionID, mimeType: mimeType)
                }
            }
            finish(connection, status: "200 OK")
            return
        }

        guard body.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: body),
              let message = object as? [String: Any] else {
            finish(connection, status: "400 Bad Request")
            return
        }

        if httpPath(from: request) == "/commit" {
            guard ProcessInfo.processInfo.environment["INSPIRATION_ENABLE_TEST_COMMIT"] == "1",
                  let sessionID = message["sessionID"] as? String else {
                finish(connection, status: "404 Not Found")
                return
            }
            let folder = message["folder"] as? String ?? ""
            var accepted = false
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    accepted = DragCoordinator.shared.commitActiveSessionForTesting(sessionID: sessionID, folder: folder)
                }
            }
            finish(connection, status: accepted ? "200 OK" : "409 Conflict")
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated { DragCoordinator.shared.handleBrowserMessage(message) }
        }
        finish(connection, status: "200 OK")
    }

    nonisolated static func httpMethod(from request: Data) -> String? {
        guard let firstLineEnd = request.range(of: Data("\r\n".utf8)),
              let line = String(data: request[..<firstLineEnd.lowerBound], encoding: .utf8) else { return nil }
        return line.split(separator: " ").first.map(String.init)
    }

    nonisolated static func httpPath(from request: Data) -> String? {
        guard let firstLineEnd = request.range(of: Data("\r\n".utf8)),
              let line = String(data: request[..<firstLineEnd.lowerBound], encoding: .utf8) else { return nil }
        let components = line.split(separator: " ")
        guard components.count >= 2 else { return nil }
        return String(components[1]).split(separator: "?", maxSplits: 1).first.map(String.init)
    }

    nonisolated static func headerValue(_ name: String, from request: Data) -> String? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter),
              let headers = String(data: request[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lowercasedName = name.lowercased()
        for line in headers.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == lowercasedName else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    nonisolated static func isTrustedExtensionRequest(_ request: Data) -> Bool {
        headerValue("x-inspiration-bridge", from: request) == extensionRequestToken
    }

    nonisolated static func contentLength(from request: Data) -> Int? {
        headerValue("content-length", from: request).flatMap(Int.init)
    }

    nonisolated static func isCompleteRequest(_ request: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter) else { return false }
        let headerData = request[..<range.lowerBound]
        guard String(data: headerData, encoding: .utf8) != nil else { return false }
        let contentLength = contentLength(from: request) ?? 0
        return request.count >= range.upperBound + contentLength
    }

    nonisolated static func httpBody(from request: Data) -> Data? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: delimiter) else { return nil }
        let body = request.subdata(in: range.upperBound..<request.endIndex)
        let headerData = request[..<range.lowerBound]
        guard String(data: headerData, encoding: .utf8) != nil else { return nil }
        let contentLength = contentLength(from: request) ?? body.count
        guard body.count >= contentLength else { return nil }
        return body.prefix(contentLength)
    }

    private nonisolated static func finish(_ connection: NWConnection, status: String, body: Data? = nil) {
        let resolvedBody = body ?? Data((status.hasPrefix("2") ? "{\"ok\":true}" : "{\"ok\":false}").utf8)
        let header = "HTTP/1.1 \(status)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-Inspiration-Bridge, X-Inspiration-Session, X-Inspiration-Mime\r\nContent-Type: application/json\r\nContent-Length: \(resolvedBody.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + resolvedBody, completion: .contentProcessed { _ in connection.cancel() })
    }
}
