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

import ContainerizationError
import Testing
@testable import ComposeCore

struct ComposeVariableInterpolatorTests {
    @Test
    func testInterpolateSupportsComposeDefaultOperators() throws {
        let values = [
            "SET": "value",
            "EMPTY": "",
            "PWD": "/workspace",
        ]

        let result = try ComposeVariableInterpolator.interpolate(
            "a=${UNSET-default} b=${UNSET:-fallback} c=${EMPTY-default} d=${EMPTY:-fallback} e=${MAIN_GIT_DIR:-$PWD/.git}"
        ) {
            values[$0]
        }

        #expect(result == "a=default b=fallback c= d=fallback e=/workspace/.git")
    }

    @Test
    func testInterpolateSupportsComposeAlternativeOperators() throws {
        let values = [
            "SET": "value",
            "EMPTY": "",
        ]

        let result = try ComposeVariableInterpolator.interpolate(
            "a=${SET+alt} b=${EMPTY+alt} c=${UNSET+alt} d=${SET:+alt} e=${EMPTY:+alt} f=${UNSET:+alt}"
        ) {
            values[$0]
        }

        #expect(result == "a=alt b=alt c= d=alt e= f=")
    }

    @Test
    func testInterpolateRejectsInvalidVariableName() throws {
        #expect {
            _ = try ComposeVariableInterpolator.interpolate("${$(echo hacked)}") { _ in nil }
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("Invalid environment variable name")
        }
    }
}
