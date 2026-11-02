import Foundation
import Network

/// Listens for the `htty` command on a Unix socket, exported to shells as
/// HYPERTTY_SOCKET. One request per connection: a line of tab-separated fields.
final class HttyServer {
    let path = NSTemporaryDirectory() + "hypertty-\(getpid()).sock"
    private let listener: NWListener

    init(onRequest: @escaping ([Substring]) -> Void) throws {
        unlink(path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            Self.receive(on: connection, buffer: Data(), onRequest: onRequest)
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        unlink(path)
    }

    private static func receive(on connection: NWConnection, buffer: Data,
                                onRequest: @escaping ([Substring]) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            let buffer = buffer + (data ?? Data())
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                if let line = String(data: buffer[..<newline], encoding: .utf8) {
                    onRequest(line.split(separator: "\t", omittingEmptySubsequences: false))
                }
                connection.cancel()
            } else if isComplete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer, onRequest: onRequest)
            }
        }
    }
}
