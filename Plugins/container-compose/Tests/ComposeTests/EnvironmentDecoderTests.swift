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
import ContainerizationError
@testable import ComposeCore

struct EnvironmentDecoderTests {
    @Test
    func invalidEnvListKeysThrow() throws {
        let yaml = """
        version: '3'
        services:
          bad:
            image: alpine
            environment:
              - "123INVALID=value"
              - 'INVALID-CHAR=value' # inline comment
              - "INVALID.DOT=value"
        """

        let log = Logger(label: "test")
        let parser = ComposeParser(log: log)
        #expect {
            _ = try parser.parse(from: yaml.data(using: .utf8)!)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("Invalid environment variable name")
        }
    }
}
