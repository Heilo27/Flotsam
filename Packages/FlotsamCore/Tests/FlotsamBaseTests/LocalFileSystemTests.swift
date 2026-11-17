import Foundation
import Testing
@testable import FlotsamBase

// TASK-378: the real `LocalFileSystem` adapter, exercised against a temp directory (no fakes, so the code under
// test is the code that ships). Expected values are literals only (TEST-DOCTRINE B2).
// OC-0004: an OS file error surfaces as .sysInt001 carrying the underlying domain and code and nothing else.
// OC-0001 / OC-0077: the file system sits behind a port.

private struct TempRoot {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotsam-localfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String = "x") throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

/// Sets an xattr with the raw syscall so the test does not depend on the adapter's own read path.
private func setRawXattr(_ name: String, _ bytes: [UInt8], at url: URL) -> Int32 {
    bytes.isEmpty
        ? setxattr(url.path, name, nil, 0, 0, 0)
        : setxattr(url.path, name, bytes, bytes.count, 0, 0)
}

@Suite struct LocalFileSystemTests {
    private let fs = LocalFileSystem()

    // MARK: createDirectory

    /// Mutant: withIntermediateDirectories true -> false (X230). Red: nested create fails on the missing parents.
    @Test func createDirectoryBuildsMissingParents() throws {
        // given: an empty temp root and a path three levels deep
        let root = try TempRoot(); defer { root.remove() }
        let deep = root.url.appendingPathComponent("a/b/c", isDirectory: true)
        // when
        let result = fs.createDirectory(at: deep, permissions: 0o700)
        // then: success, every level exists, and the leaf carries the requested mode
        #expect(result.isSuccessValue)
        for level in ["a", "a/b", "a/b/c"] {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.url.appendingPathComponent(level).path, isDirectory: &isDir)
            #expect(exists && isDir.boolValue, "\(level) should be a directory")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: deep.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(fs.fileExists(at: deep))
    }

    /// Negative: creating a directory where a regular file sits fails (it must not report success).
    @Test func createDirectoryOverAFileFails() throws {
        // given: a regular file
        let root = try TempRoot(); defer { root.remove() }
        let file = try root.file("plain")
        // when
        let result = fs.createDirectory(at: file.appendingPathComponent("child"), permissions: 0o700)
        // then
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .sysInt001)
    }

    // MARK: extendedAttribute

    /// Mutants: size-probe args (X232 size 1, X233 position 1) and read position (X239). Red: value reads back nil.
    @Test func extendedAttributeReadsStoredValue() throws {
        // given: a file with a 5-byte xattr
        let root = try TempRoot(); defer { root.remove() }
        let file = try root.file("f")
        #expect(setRawXattr("com.flotsam.test", Array("hello".utf8), at: file) == 0)
        // when / then
        #expect(fs.extendedAttribute(named: "com.flotsam.test", at: file) == Data("hello".utf8))
    }

    /// Mutants: X235/X236 (size >= 0 -> >0 / >=1) and X241/X243 (read >= 0 -> >0 / >=1). Red: a stored zero-length
    /// value is reported as missing (nil) instead of empty Data.
    @Test func zeroLengthValueIsEmptyDataNotNil() throws {
        // given: a file whose xattr exists with zero bytes
        let root = try TempRoot(); defer { root.remove() }
        let file = try root.file("f")
        #expect(setRawXattr("com.flotsam.empty", [], at: file) == 0)
        // when
        let value = fs.extendedAttribute(named: "com.flotsam.empty", at: file)
        // then: present and empty, distinct from absent
        #expect(value == Data())
        #expect(fs.extendedAttribute(named: "com.flotsam.absent", at: file) == nil)
    }

    /// Negative: a missing attribute, and a missing file, both read as nil.
    @Test func missingAttributeOrFileReadsNil() throws {
        // given: a file with one xattr set
        let root = try TempRoot(); defer { root.remove() }
        let file = try root.file("f")
        #expect(setRawXattr("com.flotsam.present", [1, 2, 3], at: file) == 0)
        // when / then
        #expect(fs.extendedAttribute(named: "com.flotsam.other", at: file) == nil)
        #expect(fs.extendedAttribute(named: "com.flotsam.present", at: root.url.appendingPathComponent("nope")) == nil)
    }

    /// Boundary: a larger binary value (every byte value, 256 bytes) round-trips byte for byte.
    @Test func binaryValueRoundTripsExactly() throws {
        // given
        let root = try TempRoot(); defer { root.remove() }
        let file = try root.file("f")
        let bytes = (0...255).map { UInt8($0) }
        #expect(setRawXattr("com.flotsam.bin", bytes, at: file) == 0)
        // when / then
        let value = fs.extendedAttribute(named: "com.flotsam.bin", at: file)
        #expect(value?.count == 256)
        #expect(value == Data(bytes))
    }

    /// Mutants: X234 (probe) and X240 (read) set XATTR_NOFOLLOW (options 1). It only matters on a symlink: the
    /// adapter follows links, so the target's attribute is returned. Red: nil (the link itself has no attribute).
    @Test func extendedAttributeFollowsSymlinks() throws {
        // given: a symlink to a file that carries the xattr
        let root = try TempRoot(); defer { root.remove() }
        let target = try root.file("target")
        #expect(setRawXattr("com.flotsam.link", Array("via-link".utf8), at: target) == 0)
        let link = root.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // when / then
        #expect(fs.extendedAttribute(named: "com.flotsam.link", at: link) == Data("via-link".utf8))
    }

    // MARK: failure mapping (OC-0004)

    /// Mutant: delete `try operation()` (X244). Red: remove reports success and the file is still on disk.
    @Test func removeItemRunsTheOperation() throws {
        // given: two files
        let root = try TempRoot(); defer { root.remove() }
        let doomed = try root.file("doomed")
        let survivor = try root.file("survivor")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.url.path).count
        // when
        let result = fs.removeItem(at: doomed)
        // then: count down by one, target gone, survivor intact
        #expect(result.isSuccessValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path).count == before - 1)
        #expect(!fs.fileExists(at: doomed))
        #expect(fs.fileExists(at: survivor))
    }

    /// Mutants: X244 (operation never runs, so no failure), X245 (message literal). OC-0004: code .sysInt001 with
    /// the underlying domain and code and the exact developer message.
    @Test func failingOperationMapsToSysInt001WithUnderlyingDomainAndCode() throws {
        // given: a path that does not exist
        let root = try TempRoot(); defer { root.remove() }
        let missing = root.url.appendingPathComponent("missing")
        // when
        let result = fs.removeItem(at: missing)
        // then: NSCocoaErrorDomain 4 is NSFileNoSuchFileError
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .sysInt001)
        #expect(error.underlying == UnderlyingErrorInfo(domain: "NSCocoaErrorDomain", code: 4))
        #expect("\(error.internalMessage)" == "File system operation failed")
        #expect(error.context.isEmpty)
    }

    /// Same mapping through the other `attempt` callers and `contentsOfDirectory`, so the mapping is one rule.
    @Test func copyMoveAndListFailuresShareTheMapping() throws {
        // given
        let root = try TempRoot(); defer { root.remove() }
        let missing = root.url.appendingPathComponent("missing")
        let dest = root.url.appendingPathComponent("dest")
        // when
        let copy = fs.copyItem(at: missing, to: dest)
        let move = fs.moveItem(at: missing, to: dest)
        let list = fs.contentsOfDirectory(at: missing)
        // then: each fails with the mapped error; nothing was created at the destination
        for error in [copy.failureValue, move.failureValue, list.failureValue] {
            #expect(error?.code == .sysInt001)
            #expect(error?.underlying?.domain == "NSCocoaErrorDomain")
            #expect("\(error?.internalMessage ?? "")" == "File system operation failed")
        }
        // NSCocoaErrorDomain 260 is NSFileReadNoSuchFileError, 4 is NSFileNoSuchFileError
        #expect(copy.failureValue?.underlying?.code == 260)
        #expect(move.failureValue?.underlying?.code == 4)
        #expect(list.failureValue?.underlying?.code == 260)
        #expect(!fs.fileExists(at: dest))
    }
}

private extension Result where Failure == FlotsamError {
    var isSuccessValue: Bool { if case .success = self { true } else { false } }
    var failureValue: FlotsamError? { if case .failure(let e) = self { e } else { nil } }
}
