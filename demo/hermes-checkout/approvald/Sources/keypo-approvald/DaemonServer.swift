import Foundation

// Global state for signal handler access (C signal handlers can't capture Swift closures)
private var globalShouldStop = false
private var globalServerSocket: Int32 = -1

class DaemonServer {
    private let socketPath: String
    private let handler: RequestHandler
    private var serverSocket: Int32 = -1
    private var running = false

    init(socketPath: String, handler: RequestHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        // Remove existing socket file
        unlink(socketPath)

        // Create Unix domain socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw DaemonError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DaemonError.socketPathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverSocket)
            throw DaemonError.bindFailed(String(cString: strerror(errno)))
        }

        // Set socket permissions (owner + group readable/writable)
        chmod(socketPath, 0o770)

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            Darwin.close(serverSocket)
            unlink(socketPath)
            throw DaemonError.listenFailed(String(cString: strerror(errno)))
        }

        running = true
        globalServerSocket = serverSocket
        log("listening on \(socketPath)")

        // Install signal handlers
        installSignalHandlers()

        // Accept loop
        while running && !globalShouldStop {
            let clientSocket = accept(serverSocket, nil, nil)
            if clientSocket < 0 {
                if globalShouldStop || !running { break }
                if errno == EINTR { continue } // Interrupted by signal, check flags
                log("accept failed: \(String(cString: strerror(errno)))")
                continue
            }

            handleConnection(clientSocket)
            Darwin.close(clientSocket)
        }

        cleanup()
    }

    func stop() {
        running = false
        globalShouldStop = true
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        globalServerSocket = -1
    }

    private func cleanup() {
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
        globalServerSocket = -1
        unlink(socketPath)
        log("socket cleaned up")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ clientSocket: Int32) {
        let fileHandle = FileHandle(fileDescriptor: clientSocket, closeOnDealloc: false)
        var buffer = Data()

        // Read until we have a complete newline-delimited message
        while true {
            let chunk = fileHandle.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)

            // Process all complete messages (newline-delimited)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                guard !messageData.isEmpty else { continue }

                let response = processMessage(Data(messageData))
                sendResponse(response, to: clientSocket)
            }

            // If buffer is getting large without a newline, bail
            if buffer.count > 1_000_000 {
                let error = ResponseMessage(
                    status: "error",
                    request_id: nil,
                    error: "message too large"
                )
                sendResponse(error, to: clientSocket)
                return
            }
        }

        // Process any remaining data without trailing newline
        if !buffer.isEmpty {
            let response = processMessage(buffer)
            sendResponse(response, to: clientSocket)
        }
    }

    private func processMessage(_ data: Data) -> ResponseMessage {
        let decoder = JSONDecoder()
        guard let message = try? decoder.decode(IncomingMessage.self, from: data) else {
            return ResponseMessage(
                status: "error",
                request_id: nil,
                error: "invalid JSON message"
            )
        }
        return handler.handle(message)
    }

    private func sendResponse(_ response: ResponseMessage, to socket: Int32) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [] // compact
        guard var data = try? encoder.encode(response) else {
            log("failed to encode response")
            return
        }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { ptr in
            _ = write(socket, ptr.baseAddress!, ptr.count)
        }
    }

    // MARK: - Signal Handling

    private func installSignalHandlers() {
        // Use C-level signal handlers that set the global flag and close the
        // server socket to unblock the accept() call.
        let handler: @convention(c) (Int32) -> Void = { _ in
            globalShouldStop = true
            // Close the server socket to unblock accept()
            if globalServerSocket >= 0 {
                Darwin.close(globalServerSocket)
                globalServerSocket = -1
            }
        }
        signal(SIGTERM, handler)
        signal(SIGINT, handler)
    }

    // MARK: - Logging

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("keypo-approvald: \(message)\n".utf8))
    }
}

// MARK: - Errors

enum DaemonError: Error, CustomStringConvertible {
    case socketCreationFailed(String)
    case socketPathTooLong
    case bindFailed(String)
    case listenFailed(String)

    var description: String {
        switch self {
        case .socketCreationFailed(let msg): return "socket creation failed: \(msg)"
        case .socketPathTooLong: return "socket path too long"
        case .bindFailed(let msg): return "bind failed: \(msg)"
        case .listenFailed(let msg): return "listen failed: \(msg)"
        }
    }
}
