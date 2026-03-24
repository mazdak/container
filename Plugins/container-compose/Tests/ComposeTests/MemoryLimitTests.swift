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

import Testing
import Logging
@testable import ComposeCore

struct MemoryLimitTests {
    let log = Logger(label: "test")

    @Test func testMemLimitStringPropagates() throws {
        let yaml = """
        version: '3'
        services:
          web:
            image: alpine
            mem_limit: "2g"
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)

        let converter = ProjectConverter(log: log)
        let project = try converter.convert(composeFile: composeFile, projectName: "mtest")

        #expect(project.services["web"]?.memory == "2g")
    }

    @Test func testMemLimitMaxPropagates() throws {
        let yaml = """
        version: '3'
        services:
          api:
            image: alpine
            mem_limit: "max"
        """

        let parser = ComposeParser(log: log)
        let composeFile = try parser.parse(from: yaml.data(using: .utf8)!)

        let project = try ProjectConverter(log: log).convert(composeFile: composeFile, projectName: "mtest")
        #expect(project.services["api"]?.memory == "max")
    }
}

