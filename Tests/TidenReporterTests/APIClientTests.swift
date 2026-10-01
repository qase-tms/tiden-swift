import Foundation
import Testing
import TidenReporterCore

struct APIClientTests {
    @Test(arguments: [408, 500, 502, 503, 504])
    func transientServerStatusRetriesAndAcceptsDuplicates(status: Int) async throws {
        let transport = MockTransport([http(status, "{}"), http(#"{"accepted":0,"duplicates":1,"errors":[]}"#)])
        let client = APIClient(config: onlineConfig(), transport: transport, sleeper: RecordingSleeper())
        try await client.report(APIClient.batches([sampleRow()], size: 200), run: RunHandle(sequence: 1, ownsCompletion: true))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].body == requests[1].body)
    }
    @Test func exhaustedRetriesAreBoundedAndRedirectIsRejected() async throws {
        let exhausted = MockTransport(Array(repeating: .connectionError, count: 6))
        let sleeper = RecordingSleeper()
        let client = APIClient(config: onlineConfig(), transport: exhausted, sleeper: sleeper)
        await #expect(throws: ReporterError.self) { try await client.report(APIClient.batches([sampleRow()], size: 200), run: RunHandle(sequence: 1, ownsCompletion: true)) }
        #expect(await exhausted.requests.count == 6)
        #expect(await sleeper.delays == [1, 2, 4, 8, 16])
        let redirect = MockTransport([http(302, "{}", headers: ["location": "https://other.invalid"] )])
        let redirected = APIClient(config: onlineConfig(), transport: redirect)
        await #expect(throws: ReporterError.self) { try await redirected.report(APIClient.batches([sampleRow()], size: 200), run: RunHandle(sequence: 1, ownsCompletion: true)) }
        #expect(await redirect.requests.count == 1)
    }
    @Test func retryRetainsExactBytesAndResultIDs() async throws {
        let transport = MockTransport([.connectionError, http(429, "{}", headers: ["retry-after": "2"]), http(#"{"accepted":"1","duplicates":"0","errors":[]}"#)])
        let sleeper = RecordingSleeper()
        let client = APIClient(config: onlineConfig(), transport: transport, sleeper: sleeper)
        let payloads = try APIClient.batches([sampleRow()], size: 200)
        try await client.report(payloads, run: RunHandle(sequence: 7, ownsCompletion: true))
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.body == payloads[0] })
        #expect(requests.allSatisfy { $0.url.path.hasSuffix("/runs/7/results:report") })
        #expect(await sleeper.delays == [1, 2])
    }
    @Test func createRunIsNotRetriedAfterAmbiguousConnection() async {
        let transport = MockTransport([.connectionError, http(#"{"run":{"seqNum":9}}"#)])
        let client = APIClient(config: onlineConfig(), transport: transport, sleeper: RecordingSleeper())
        await #expect(throws: ReporterError.self) { try await client.begin() }
        #expect(await transport.requests.count == 1)
    }
    @Test func runSequenceComesFromNestedResponseAndOwnershipIsExplicit() async throws {
        let transport = MockTransport([http(#"{"seqNum":999,"run":{"seqNum":"7"}}"#), http("{}")])
        let client = APIClient(config: onlineConfig(), transport: transport)
        let run = try await client.begin()
        #expect(run.sequence == 7)
        try await client.finish(run, trustworthy: false)
        let requests = await transport.requests
        #expect(requests[1].url.path.hasSuffix("/runs/7:abort"))
        #expect(requests[1].body == Data("{}".utf8))
        var joined = onlineConfig()
        joined.runID = 8
        joined.complete = false
        let noRequests = MockTransport([])
        let joinedClient = APIClient(config: joined, transport: noRequests)
        let handle = try await joinedClient.begin()
        try await joinedClient.finish(handle, trustworthy: true)
        try await joinedClient.finish(handle, trustworthy: false)
        #expect(await noRequests.requests.isEmpty)
    }
    @Test(arguments: [#"{"accepted":"0","duplicates":"0","errors":[]}"#, #"{"accepted":"9223372036854775807","duplicates":"9223372036854775807","errors":[]}"#, #"{"accepted":"1","duplicates":"0","errors":[{"index":0,"resultId":"id","code":"INVALID","message":"bad test-secret"}]}"#])
    func acknowledgmentErrorsNeverCompleteAndAreRedacted(response: String) async throws {
        let transport = MockTransport([http(response)])
        let client = APIClient(config: onlineConfig(), transport: transport)
        do {
            try await client.report(APIClient.batches([sampleRow()], size: 200), run: RunHandle(sequence: 1, ownsCompletion: true))
            Issue.record("Invalid acknowledgment was accepted")
        } catch {
            #expect(!String(describing: error).contains("test-secret"))
            if response.contains("INVALID") { #expect(String(describing: error).contains("Result #0 (id=id): INVALID: bad [REDACTED]")) }
        }
    }
    @Test func deterministicRejectionIsNotRetriedAndKeepsReason() async throws {
        let transport = MockTransport([http(400, #"{"message":"run is completed","errors":[{"index":0,"resultId":"abc","code":"LOCKED","message":"cannot update"}]}"#)])
        let client = APIClient(config: onlineConfig(), transport: transport)
        do { try await client.report(APIClient.batches([sampleRow()], size: 200), run: RunHandle(sequence: 1, ownsCompletion: true)); Issue.record("Rejection accepted") }
        catch { #expect(String(describing: error).contains("run is completed")); #expect(String(describing: error).contains("LOCKED")) }
        #expect(await transport.requests.count == 1)
    }
    @Test func batchingRespectsCountAndPayloadLimits() throws {
        let rows = (0..<3).map { sampleRow(id: "00000000-0000-4000-8000-00000000000\($0)") }
        #expect(try APIClient.batches(rows, size: 2).map { try JSONValue.decode($0)["results"].array.count } == [2, 1])
        var large = sampleRow()
        large.message = String(repeating: "x", count: 5 * 1024 * 1024)
        #expect(try APIClient.batches([large, large], size: 200).count == 2)
        large.message = String(repeating: "x", count: 9 * 1024 * 1024)
        #expect(throws: ReporterError.self) { try APIClient.batches([large], size: 200) }
    }
    @Test func attachmentMultipartReturnsContentHashAndValidatesCount() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        try Data([0, 1, 2, 3]).write(to: file)
        let hash = String(repeating: "a", count: 64)
        let transport = MockTransport([http("{\"status\":true,\"result\":[{\"hash\":\"\(hash)\"}]}"), http(#"{"status":true,"result":[]}"#)])
        let client = APIClient(config: onlineConfig(), transport: transport)
        #expect(try await client.upload(file: file, name: "capture\"\n.png", mime: "image/png", boundary: "boundary") == hash)
        let request = await transport.requests[0]
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=boundary")
        #expect(request.body.starts(with: Data("--boundary\r\nContent-Disposition: form-data; name=\"file[]\"; filename=\"capture__.png\"\r\n".utf8)))
        #expect(request.body.contains(Data([0, 1, 2, 3])))
        await #expect(throws: ReporterError.self) { try await client.upload(file: file, name: "capture.png", mime: "image/png") }
    }
}
