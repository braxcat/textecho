import Foundation
import Darwin

/// Unix domain socket utilities — used by LLMClient for IPC with the optional Python LLM daemon.
enum UnixSocket {
    static func request(socketPath: String, header: [String: Any], body: Data?) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("socket") }
        defer { close(fd) }

        // Set 30-second send and receive timeouts
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = socketPath.data(using: .utf8) ?? Data()
        if pathData.count >= MemoryLayout.size(ofValue: addr.sun_path) {
            throw NSError(domain: "TextEcho.Socket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Socket path too long"])
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            pathData.copyBytes(to: UnsafeMutableRawBufferPointer(start: ptr, count: pathData.count))
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                connect(fd, ptr, len)
            }
        }
        guard connectResult == 0 else { throw socketError("connect") }

        let headerData = try JSONSerialization.data(withJSONObject: header, options: [])
        var packet = Data()
        packet.append(headerData)
        packet.append(Data([0x0A]))
        if let body {
            packet.append(body)
        }

        try packet.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var remaining = buffer.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, base.advanced(by: offset), remaining)
                if written < 0 { throw socketError("write") }
                remaining -= written
                offset += written
            }
        }

        let responseData = try readLine(fd: fd)
        guard let json = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw NSError(domain: "TextEcho.Socket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        return json
    }

    static func ping(socketPath: String, command: String) -> Bool {
        do {
            let response = try request(socketPath: socketPath, header: ["command": command], body: nil)
            return (response["success"] as? Bool) == true || response["pong"] as? Bool == true || response["model_loaded"] != nil
        } catch {
            return false
        }
    }

    private static func readLine(fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw socketError("read") }
            if count == 0 { break }
            if let newlineIndex = buffer[0..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[0..<newlineIndex])
                break
            }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    private static func socketError(_ op: String) -> NSError {
        let code = Int(errno)
        let message = String(cString: strerror(errno))
        return NSError(domain: "TextEcho.Socket", code: code, userInfo: [NSLocalizedDescriptionKey: "\(op) failed: \(message)"])
    }
}
