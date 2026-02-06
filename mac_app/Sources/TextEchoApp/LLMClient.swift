import Foundation

final class LLMClient {
    static let shared = LLMClient()
    private let queue = DispatchQueue(label: "textecho.llm", qos: .userInitiated)

    func send(prompt: String, context: String, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            do {
                let socketPath = AppConfig.shared.model.llmSocket
                let response = try UnixSocket.request(
                    socketPath: socketPath,
                    header: [
                        "command": "generate",
                        "prompt": prompt,
                        "context": context
                    ],
                    body: nil
                )

                if let success = response["success"] as? Bool, success {
                    let text = response["response"] as? String ?? ""
                    completion(.success(text))
                } else {
                    let message = response["error"] as? String ?? "Unknown error"
                    completion(.failure(NSError(domain: "TextEcho.LLM", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
