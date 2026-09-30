import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) { self.status = status; self.headers = headers; self.body = body }
}
public protocol HTTPTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse
}
public protocol Sleeping: Sendable { func sleep(seconds: Double) async throws }
public struct TaskSleeper: Sleeping {
    public init() {}
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Redirects are deliberately rejected, including same-origin redirects; API paths must be canonical.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 360
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func post(url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReporterError("API returned a non-HTTP response") }
        var normalized: [String: String] = [:]
        for (key, value) in response.allHeaderFields { normalized[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPResponse(status: response.statusCode, headers: normalized, body: data)
    }
}

public actor APIClient {
    public static let payloadLimit = 8 * 1024 * 1024
    private let config: Configuration
    private let transport: any HTTPTransport
    private let sleeper: any Sleeping
    private let now: @Sendable () -> Date
    public init(config: Configuration, transport: any HTTPTransport = URLSessionTransport(), sleeper: any Sleeping = TaskSleeper(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.transport = transport; self.sleeper = sleeper; self.now = now
    }
    private func url(_ suffix: String) throws -> URL {
        guard let product = config.product, config.token != nil else { throw ReporterError("API credentials/product are missing") }
        return config.baseURL.appendingPathComponent("v1/products/\(product)\(suffix)")
    }
    private func send(_ suffix: String, body: Data, contentType: String = "application/json", retrySafe: Bool = true) async throws -> Data {
        let url = try url(suffix)
        let headers = ["Authorization": "Bearer \(config.token!)", "Content-Type": contentType, "Accept": "application/json"]
        let retryable: Set<Int> = [408, 429, 500, 502, 503, 504]
        for attempt in 0...5 {
            try Task.checkCancellation()
            let response: HTTPResponse
            do { response = try await transport.post(url: url, headers: headers, body: body) }
            catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard retrySafe, attempt < 5 else {
                    throw ReporterError(retrySafe ? "API connection failed after retries; payload retained locally" : "Create-run response is ambiguous; refusing to retry and create a duplicate run")
                }
                try await sleeper.sleep(seconds: min(pow(2, Double(attempt)), 30)); continue
            }
            if (200..<300).contains(response.status) { return response.body }
            guard retrySafe, retryable.contains(response.status), attempt < 5 else {
                throw ReporterError(config.redact("API POST \(suffix) failed with HTTP \(response.status). \(Self.refusal(response.body)) Payload retained locally."))
            }
            var delay = min(pow(2, Double(attempt)), 30)
            if let text = response.headers["retry-after"] {
                if let seconds = Double(text), seconds.isFinite { delay = min(max(seconds, 0), 30) }
                else {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: text) { delay = min(max(date.timeIntervalSince(now()), 0), 30) }
                }
            }
            try await sleeper.sleep(seconds: delay)
        }
        throw ReporterError("API retries exhausted")
    }
    public func begin() async throws -> RunHandle {
        if let sequence = config.runID { return RunHandle(sequence: sequence, ownsCompletion: config.complete) }
        let response = try JSONValue.decode(await send("/runs", body: Wire.encode(CreateRun(config: config, now: now())), retrySafe: false))
        guard let sequence = response["run"]["seqNum"].integer, (1...Int(Int32.max)).contains(sequence) else {
            throw ReporterError("Create-run response lacks run.seqNum; run may exist; refusing to create another")
        }
        return RunHandle(sequence: sequence, ownsCompletion: config.complete)
    }
    public static func batches(_ rows: [ResultCreate], size: Int) throws -> [Data] {
        guard (1...2000).contains(size) else { throw ReporterError("Batch size must be 1...2000") }
        struct Batch: Encodable { let results: [ResultCreate] }
        var payloads: [Data] = [], current: [ResultCreate] = []
        for row in rows {
            let proposed = current + [row]
            let encoded = try Wire.encode(Batch(results: proposed))
            if proposed.count > size || encoded.count > payloadLimit {
                guard !current.isEmpty else { throw ReporterError("One result exceeds the 8 MiB request limit") }
                payloads.append(try Wire.encode(Batch(results: current))); current = [row]
                guard try Wire.encode(Batch(results: current)).count <= payloadLimit else { throw ReporterError("One result exceeds the 8 MiB request limit") }
            } else { current = proposed }
        }
        if !current.isEmpty { payloads.append(try Wire.encode(Batch(results: current))) }
        return payloads
    }
    public func report(_ payloads: [Data], run: RunHandle) async throws {
        for payload in payloads {
            let count = try JSONValue.decode(payload)["results"].array.count
            guard (1...2000).contains(count), payload.count <= Self.payloadLimit else { throw ReporterError("Invalid persisted result batch") }
            let response = try JSONValue.decode(await send("/runs/\(run.sequence)/results:report", body: payload))
            guard let accepted = response["accepted"].integer, let duplicates = response["duplicates"].integer,
                  (0...count).contains(accepted), (0...count).contains(duplicates), accepted == count - duplicates,
                  response["errors"].array.isEmpty, response["errors"] == .null || {
                      if case .array = response["errors"] { return true }; return false
                  }() else { throw ReporterError(config.redact("Results acknowledgment mismatch; refusing run completion. \(Self.refusal(try Wire.encode(response)))")) }
        }
    }
    private static func refusal(_ body: Data) -> String {
        guard let decoded = try? JSONValue.decode(body) else { return "Server returned no JSON reason." }
        var lines: [String] = []
        if let message = decoded["message"].string { lines.append(String(message.prefix(2000))) }
        for error in decoded["errors"].array.prefix(20) {
            let index = error["index"].integer.map(String.init) ?? "?"
            let id = error["resultId"].string ?? "?"
            let code = error["code"].string ?? "UNKNOWN"
            let message = String((error["message"].string ?? "").prefix(2000))
            lines.append("Result #\(index) (id=\(id)): \(code): \(message)")
        }
        return lines.joined(separator: "\n")
    }
    public func finish(_ run: RunHandle, trustworthy: Bool) async throws {
        guard run.ownsCompletion else { return }
        _ = try await send("/runs/\(run.sequence):\(trustworthy ? "complete" : "abort")", body: Data("{}".utf8))
    }
    public func upload(file: URL, name: String, mime: String, boundary: String = UUID().uuidString) async throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value <= 32 * 1024 * 1024 else { throw ReporterError("Attachment exceeds 32 MiB") }
        let contents = try Data(contentsOf: file, options: .mappedIfSafe)
        guard contents.count <= 32 * 1024 * 1024 else { throw ReporterError("Attachment grew beyond 32 MiB") }
        let safeName = name.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file[]\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(contents); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try JSONValue.decode(await send("/attachments:upload", body: body, contentType: "multipart/form-data; boundary=\(boundary)"))
        guard response["status"].bool == true, response["result"].array.count == 1,
              let hash = response["result"].array.first?["hash"].string,
              hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ReporterError("Attachment upload returned an invalid hash/count")
        }
        return hash
    }
}
