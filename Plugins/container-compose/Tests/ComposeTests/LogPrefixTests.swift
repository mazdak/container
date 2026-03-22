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
@testable import ComposePlugin

struct LogPrefixTests {

    @Test func testPlainPrefixPadding() {
        let s = LogPrefixFormatter.coloredPrefix(for: "api", width: 6, colorEnabled: false)
        #expect(s == "api    | ")
    }

    @Test func testPlainPrefixTruncate() {
        let name = String(repeating: "x", count: 50)
        // width param simulates the capped width TargetsUtil returns (<= 40)
        let s = LogPrefixFormatter.coloredPrefix(for: name, width: 40, colorEnabled: false)
        #expect(s == String(repeating: "x", count: 40) + " | ")
    }
}
