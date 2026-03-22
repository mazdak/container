//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import ContainerAPIClient

struct ArchiverTests {
    @Test
    func testCompressAndUncompressPreservesRelativeSymbolicLink() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let targetURL = sourceURL.appendingPathComponent("target.txt")
        try #require("hello".data(using: .utf8)).write(to: targetURL)
        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "target.txt")

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path) == "target.txt")
        #expect(try String(contentsOf: destinationURL.appendingPathComponent("target.txt"), encoding: .utf8) == "hello")
    }

    @Test
    func testCompressAndUncompressPreservesAbsoluteSymbolicLink() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        let archiveURL = tempURL.appendingPathComponent("archive.tar.gz")
        let destinationURL = tempURL.appendingPathComponent("destination")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let externalTargetURL = tempURL.appendingPathComponent("external-target.txt")
        try #require("external".data(using: .utf8)).write(to: externalTargetURL)
        let linkURL = sourceURL.appendingPathComponent("absolute-link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: externalTargetURL.path)

        _ = try Archiver.compress(source: sourceURL, destination: archiveURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        try Archiver.uncompress(source: archiveURL, destination: destinationURL)

        let extractedLinkURL = destinationURL.appendingPathComponent("absolute-link.txt")
        let values = try extractedLinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extractedLinkURL.path) == externalTargetURL.path)
    }

    @Test
    func testCompressDigestChangesWhenSymlinkTargetChanges() throws {
        let fileManager = FileManager.default
        let tempURL = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        let sourceURL = tempURL.appendingPathComponent("source")
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let firstTargetURL = sourceURL.appendingPathComponent("first.txt")
        let secondTargetURL = sourceURL.appendingPathComponent("second.txt")
        try #require("first".data(using: .utf8)).write(to: firstTargetURL)
        try #require("second".data(using: .utf8)).write(to: secondTargetURL)

        let linkURL = sourceURL.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "first.txt")

        let firstArchiveURL = tempURL.appendingPathComponent("first.tar.gz")
        let firstDigest = try archiveDigest(sourceURL: sourceURL, destinationURL: firstArchiveURL)

        try fileManager.removeItem(at: linkURL)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "second.txt")

        let secondArchiveURL = tempURL.appendingPathComponent("second.tar.gz")
        let secondDigest = try archiveDigest(sourceURL: sourceURL, destinationURL: secondArchiveURL)

        #expect(firstDigest != secondDigest)
    }

    private func archiveDigest(sourceURL: URL, destinationURL: URL) throws -> String {
        let digest = try Archiver.compress(source: sourceURL, destination: destinationURL) { url in
            let sourcePath = sourceURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let relativePath = String(path.dropFirst(sourcePath.count + 1))
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relativePath)
            )
        }

        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
