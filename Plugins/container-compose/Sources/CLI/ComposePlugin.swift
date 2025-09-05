//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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

import ArgumentParser
import ContainerClient
import Foundation
import ContainerLog
import Logging

// Import Flags namespace from main container CLI
struct Flags {
    struct Global: ParsableArguments {
        @Flag(name: .shortAndLong, help: "Enable debug logging")
        var debug = false

        @Flag(name: .long, help: "Allow YAML anchors and merge keys in compose files")
        var allowAnchors = false
    }
}

@main
struct ComposePlugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Manage multi-container applications",
        subcommands: [
            ComposeUp.self,
            ComposeDown.self,
            ComposePS.self,
            ComposeStart.self,
            ComposeStop.self,
            ComposeRestart.self,
            ComposeLogs.self,
            ComposeExec.self,
            ComposeHealth.self,
            ComposeValidate.self,
            ComposeRm.self,
        ]
    )
}
