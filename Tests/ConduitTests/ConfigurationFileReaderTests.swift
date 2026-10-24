// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyKernel

/// The bounded configuration-file reader (decisions 0021 and 0026). Real scratch files cover the approved limit, the refusals that must not
/// block and the release of every descriptor. The collector is driven directly for chunking, for growth during a read and
/// for a failed read step.
final class ConfigurationFileReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-file-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFile(bytes count: Int, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: UInt8(ascii: " "), count: count).write(to: url)
        return url
    }

    /// Records every descriptor the reader closes. The real `close` runs, so a test can prove the descriptor is gone.
    private final class CloseRecorder {
        private(set) var descriptors: [Int32] = []

        func close(_ descriptor: Int32) -> Int32 {
            descriptors.append(descriptor)
            return Darwin.close(descriptor)
        }
    }

    private func isOpen(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_GETFD) != -1
    }

    // MARK: - The budget

    func testTheApprovedBudgetIsEightMiBAndSeparateFromTheFrameCap() {
        XCTAssertEqual(ConfigurationFileReader.maximumBytes, 8_388_608)
        XCTAssertEqual(DomainResourceLimits.runtimeConfigurationFileBytes, 8_388_608)
    }

    func testAFileExactlyAtTheApprovedBudgetIsReadWhole() throws {
        let url = try makeFile(bytes: ConfigurationFileReader.maximumBytes)
        XCTAssertEqual(try ConfigurationFileReader.read(at: url).count, ConfigurationFileReader.maximumBytes)
    }

    func testAFileOneByteOverTheApprovedBudgetIsRefusedWithoutItsProbeByte() throws {
        let limit = ConfigurationFileReader.maximumBytes
        let url = try makeFile(bytes: limit + 1)
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: url)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.tooLarge(limit: limit), closeErrno: nil))
        }
    }

    func testExactAndOneOverTheLimitAcrossChunkBoundaries() throws {
        let limit = 2 * ConfigurationFileCollector.chunkBytes + 7
        let exact = try makeFile(bytes: limit)
        XCTAssertEqual(try ConfigurationFileReader.read(at: exact, limit: limit, closeDescriptor: { Darwin.close($0) }).count, limit)

        let over = try makeFile(bytes: limit + 1)
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: over, limit: limit, closeDescriptor: { Darwin.close($0) })) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.tooLarge(limit: limit), closeErrno: nil))
        }
    }

    func testAnEmptyFileIsReadAsEmpty() throws {
        let url = try makeFile(bytes: 0)
        XCTAssertEqual(try ConfigurationFileReader.read(at: url), Data())
    }

    // MARK: - What is refused without being read

    func testAMissingFileIsReportedAsMissing() {
        let url = directory.appendingPathComponent("absent.json")
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: url)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .missing)
        }
    }

    func testADirectoryIsRefusedAsNotARegularFile() {
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: directory)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: nil))
        }
    }

    func testANamedPipeIsRefusedWithoutBlocking() throws {
        let url = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: url)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: nil))
        }
    }

    func testASymbolicLinkToANamedPipeIsRefusedWithoutBlocking() throws {
        let pipe = directory.appendingPathComponent("pipe")
        let link = directory.appendingPathComponent("pipe-link")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pipe)
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: link)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: nil))
        }
    }

    func testACharacterDeviceIsRefusedWithoutBlocking() {
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: URL(fileURLWithPath: "/dev/null"))) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: nil))
        }
    }

    func testASymbolicLinkToARegularFileIsFollowed() throws {
        let target = try makeFile(bytes: 12)
        let link = directory.appendingPathComponent("config-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try ConfigurationFileReader.read(at: link).count, 12)
    }

    // MARK: - Descriptors are released on every path

    func testEveryOpenedDescriptorIsClosedOnEveryPath() throws {
        let recorder = CloseRecorder()
        let regular = try makeFile(bytes: 5)
        let pipe = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)

        XCTAssertEqual(try ConfigurationFileReader.read(at: regular, limit: 5, closeDescriptor: recorder.close).count, 5)
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: regular, limit: 4, closeDescriptor: recorder.close)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.tooLarge(limit: 4), closeErrno: nil))
        }
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: pipe, limit: 5, closeDescriptor: recorder.close)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: nil))
        }
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: directory.appendingPathComponent("absent"), limit: 5, closeDescriptor: recorder.close)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .missing)
        }

        // A missing file never opens a descriptor, so only the three opened reads close one.
        XCTAssertEqual(recorder.descriptors.count, 3)
        for descriptor in recorder.descriptors {
            XCTAssertFalse(isOpen(descriptor), "descriptor \(descriptor) stayed open")
        }
    }

    func testAFailedCloseAfterAGoodReadIsSurfacedAndTheDescriptorIsStillReleased() throws {
        let regular = try makeFile(bytes: 3)
        var closed: Int32?
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: regular, limit: 3, closeDescriptor: { descriptor in
            closed = descriptor
            _ = Darwin.close(descriptor)
            errno = EIO
            return -1
        })) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .closeFailed(EIO))
        }
        let descriptor = try XCTUnwrap(closed)
        XCTAssertFalse(isOpen(descriptor))
    }

    func testARefusedReadAndAFailedCloseAreBothKept() throws {
        let pipe = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let regular = try makeFile(bytes: 9)
        let failingClose: (Int32) -> Int32 = { descriptor in
            _ = Darwin.close(descriptor)
            errno = EIO
            return -1
        }

        XCTAssertThrowsError(try ConfigurationFileReader.read(at: pipe, limit: 9, closeDescriptor: failingClose)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.notRegularFile, closeErrno: EIO))
        }
        XCTAssertThrowsError(try ConfigurationFileReader.read(at: regular, limit: 4, closeDescriptor: failingClose)) { error in
            XCTAssertEqual(error as? ConfigurationFileError, .unreadable(.tooLarge(limit: 4), closeErrno: EIO))
        }
    }

    // MARK: - The collector seam

    func testTheCollectorDeliversExactlyTheLimitAndNoMore() throws {
        var remaining = 100
        let data = try ConfigurationFileCollector.collect(limit: 100) { buffer in
            let count = min(buffer.count, remaining, 30)
            remaining -= count
            return count
        }
        XCTAssertEqual(data.count, 100)
    }

    func testGrowthPastTheLimitIsRefusedAtTheProbeByte() {
        // An endless source: the file keeps growing after its size was read. The reader takes limit + 1 bytes and stops.
        var delivered = 0
        XCTAssertThrowsError(try ConfigurationFileCollector.collect(limit: 100) { buffer in
            let count = min(buffer.count, 40)
            delivered += count
            return count
        }) { error in
            XCTAssertEqual(error as? ConfigurationFileReadStep, .tooLarge(limit: 100))
        }
        XCTAssertEqual(delivered, 101, "the reader took the limit plus one probe byte and no more")
    }

    func testEveryRequestIsBoundedByTheChunkAndByWhatIsStillAllowed() {
        var requests: [Int] = []
        var delivered = 0
        XCTAssertThrowsError(try ConfigurationFileCollector.collect(limit: 1_000_000) { buffer in
            requests.append(buffer.count)
            delivered += buffer.count
            return buffer.count
        })
        XCTAssertEqual(requests.max(), ConfigurationFileCollector.chunkBytes)
        XCTAssertEqual(delivered, 1_000_001, "the reader never asks past limit + 1 in total")
    }

    func testAReadStepFailureIsSurfacedAsItsErrno() {
        XCTAssertThrowsError(try ConfigurationFileCollector.collect(limit: 10) { _ throws(ConfigurationFileReadStep) -> Int in
            throw .readFailed(EIO)
        }) { error in
            XCTAssertEqual(error as? ConfigurationFileReadStep, .readFailed(EIO))
        }
    }

    func testACountBeyondTheRequestIsRefusedAsAFailedRead() {
        XCTAssertThrowsError(try ConfigurationFileCollector.collect(limit: 10) { buffer in
            buffer.count + 1
        }) { error in
            XCTAssertEqual(error as? ConfigurationFileReadStep, .readFailed(EIO))
        }
    }
}
