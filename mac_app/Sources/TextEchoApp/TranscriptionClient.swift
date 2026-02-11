import Foundation
import Darwin

final class TranscriptionClient {
    private let queue = DispatchQueue(label: "textecho.transcription", qos: .userInitiated)

    func transcribeRaw(audioData: Data, sampleRate: Double, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                let socketPath = AppConfig.shared.model.transcriptionSocket
                let response = try UnixSocket.request(
                    socketPath: socketPath,
                    header: [
                        "command": "transcribe_raw",
                        "sample_rate": Int(sampleRate),
                        "data_length": audioData.count
                    ],
                    body: audioData
                )

                if let success = response["success"] as? Bool, success {
                    let text = response["transcription"] as? String ?? ""
                    completion(.success(text))
                } else {
                    let message = response["error"] as? String ?? "Unknown error"
                    completion(.failure(NSError(domain: "TextEcho.Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
                }
            } catch {
                completion(.failure(TranscriptionClient.userFriendlyError(error)))
            }
        }
    }
}

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

extension TranscriptionClient {
    static func userFriendlyError(_ error: Error) -> NSError {
        let nsError = error as NSError
        let raw = nsError.localizedDescription.lowercased()

        let friendly: String
        if raw.contains("connection refused") {
            friendly = "Transcription daemon not running. Restart TextEcho from the menu bar."
        } else if raw.contains("no such file") || raw.contains("socket path") {
            friendly = "Transcription socket not found. The daemon may still be starting — try again in a moment."
        } else if raw.contains("timed out") || raw.contains("resource temporarily unavailable") {
            friendly = "Transcription timed out. The model may be loading — try again shortly."
        } else if raw.contains("broken pipe") {
            friendly = "Lost connection to transcription daemon. It may have crashed — check Logs."
        } else if raw.contains("invalid response") {
            friendly = "Received unexpected response from daemon. Check Python log for errors."
        } else {
            return nsError
        }

        return NSError(domain: nsError.domain, code: nsError.code, userInfo: [NSLocalizedDescriptionKey: friendly])
    }
}
