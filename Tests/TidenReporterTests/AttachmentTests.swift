import Foundation
import Testing
@testable import TidenXCResult
import TidenReporterCore

struct AttachmentTests {
    @Test func associatesByModuleArgumentsDeviceConfigurationAndRepetition() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("capture.png"))
        let chosen = ExecutionContext(module: "Tests", declaration: "Suite/pass", arguments: ["2", "1"], deviceID: "device", configurationID: "config", configurationName: "Default", repetition: 2)
        var other = chosen; other.arguments = ["1", "2"]
        var anotherModule = chosen; anotherModule.module = "UITests"
        var otherDevice = chosen; otherDevice.deviceID = "other-device"
        var otherConfiguration = chosen; otherConfiguration.configurationID = "other-config"; otherConfiguration.configurationName = "Other"
        var otherRepetition = chosen; otherRepetition.repetition = 1
        let manifest = try json(#"[{"testIdentifierURL":"test://com.apple.xcode/Project/Tests/Suite/pass","attachments":[{"exportedFileName":"capture.png","suggestedHumanReadableName":"Screenshot","arguments":["2","1"],"deviceId":"device","configurationName":"Default","repetitionNumber":2}]}]"#)
        let result = AttachmentMatcher.resolve(manifest: manifest, root: root, contexts: [other, chosen, anotherModule, otherDevice, otherConfiguration, otherRepetition])
        #expect(result.errors.isEmpty)
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.rowIndex == 1)
        #expect(result.matches.first?.mime == "image/png")
    }
    @Test func ambiguityFailsInsteadOfAttachingToEveryAttempt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("capture.txt"))
        let manifest = try json(#"[{"testIdentifier":"Suite/pass()","attachments":[{"exportedFileName":"capture.txt","suggestedHumanReadableName":"Log"}]}]"#)
        let context = ExecutionContext(module: "Tests", declaration: "Suite/pass")
        let result = AttachmentMatcher.resolve(manifest: manifest, root: root, contexts: [context, context])
        #expect(result.matches.isEmpty)
        #expect(result.errors.contains { $0.contains("matches 2 executions") })
        var first = context; first.startTime = 100; first.endTime = 101
        var second = context; second.startTime = 200; second.endTime = 201
        var attachment = manifest.array[0]["attachments"].array[0].object
        attachment["timestamp"] = .number(200.5)
        let timedManifest = JSONValue.array([.object(["testIdentifier": .string("Suite/pass()"), "attachments": .array([.object(attachment)])])])
        let timed = AttachmentMatcher.resolve(manifest: timedManifest, root: root, contexts: [first, second])
        #expect(timed.errors.isEmpty)
        #expect(timed.matches.first?.rowIndex == 1)
    }
    @Test func rejectsTraversalAndSymlinkFilesAndDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("real.txt")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.txt"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"), withDestinationURL: root)
        for path in ["../escape.txt", "/tmp/escape.txt", "linked.txt", "dir/real.txt"] {
            #expect(throws: (any Error).self) { try AttachmentMatcher.secureFile(path, root: root) }
        }
        #expect(try AttachmentMatcher.secureFile("real.txt", root: root) == file)
    }
    @Test func oversizedAttachmentIsExplicitlyOmittedAndRetainedLocally() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentMatcher.fileLimit + 1))
        try handle.close()
        let manifest = try json(#"[{"testIdentifier":"Suite/pass()","attachments":[{"exportedFileName":"large.bin","suggestedHumanReadableName":"Large artifact"}]}]"#)
        let result = AttachmentMatcher.resolve(manifest: manifest, root: root, contexts: [ExecutionContext(module: "Tests", declaration: "Suite/pass")])
        #expect(result.errors.isEmpty)
        #expect(result.matches.first?.skippedForSize == true)
        #expect(result.diagnostics.contains { $0.contains("preserved locally") })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
