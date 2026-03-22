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
import Foundation

enum ComposeShellWords {
    private enum QuoteState {
        case single
        case double
    }

    static func split(_ input: String) throws -> [String] {
        guard !input.isEmpty else {
            return []
        }

        var result: [String] = []
        var current = ""
        var quoteState: QuoteState?
        var escaping = false
        var startedToken = false

        func finishToken() {
            guard startedToken || !current.isEmpty else {
                return
            }
            result.append(current)
            current.removeAll(keepingCapacity: true)
            startedToken = false
        }

        for character in input {
            if escaping {
                current.append(character)
                startedToken = true
                escaping = false
                continue
            }

            switch quoteState {
            case .single:
                if character == "'" {
                    quoteState = nil
                } else {
                    current.append(character)
                }
                startedToken = true
            case .double:
                if character == "\"" {
                    quoteState = nil
                } else if character == "\\" {
                    escaping = true
                    startedToken = true
                } else {
                    current.append(character)
                    startedToken = true
                }
            case nil:
                if character == "\\" {
                    escaping = true
                    startedToken = true
                } else if character == "'" {
                    quoteState = .single
                    startedToken = true
                } else if character == "\"" {
                    quoteState = .double
                    startedToken = true
                } else if character.isWhitespace {
                    finishToken()
                } else {
                    current.append(character)
                    startedToken = true
                }
            }
        }

        if escaping {
            throw ContainerizationError(.invalidArgument, message: "Invalid command string: trailing escape")
        }
        if quoteState != nil {
            throw ContainerizationError(.invalidArgument, message: "Invalid command string: unterminated quote")
        }

        finishToken()
        return result
    }
}
