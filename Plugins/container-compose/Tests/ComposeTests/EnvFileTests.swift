//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import Logging
@testable import ComposeCore

struct EnvFileTests {
    let log = Logger(label: "test")

    @Test
    func testEnvFileMergesIntoEnvironment() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let envPath = tempDir.appendingPathComponent(".myenv")
        try "A=1\nB=2\n# comment\nexport C=3\nQUOTED='x y'\n".write(to: envPath, atomically: true, encoding: .utf8)

        let yaml = """
        version: '3'
        services:
          app:
            image: alpine
            env_file:
              - ./.myenv
            environment:
              B: override
              D: 4
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)
        let converter = ProjectConverter(log: log)

        // Change cwd to temp to resolve relative env_file
        let cwd = fm.currentDirectoryPath
        defer { _ = fm.changeCurrentDirectoryPath(cwd) }
        _ = fm.changeCurrentDirectoryPath(tempDir.path)

        let project = try converter.convert(composeFile: composeFile, projectName: "test")
        let env = try #require(project.services["app"]) .environment
        #expect(env["A"] == "1")
        #expect(env["B"] == "override") // environment overrides env_file
        #expect(env["C"] == "3")
        #expect(env["D"] == "4")
        #expect(env["QUOTED"] == "x y")
    }
}

