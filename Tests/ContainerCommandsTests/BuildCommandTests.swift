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

@testable import ContainerCommands

struct BuildCommandTests {
    @Test
    func testStagedDockerfileArtifactsSkipStagingWithoutIgnoreFile() {
        let artifacts = Application.BuildCommand.stagedDockerfileArtifacts(
            buildFileData: Data("FROM scratch\n".utf8),
            ignoreFileData: nil
        )

        #expect(artifacts == nil)
    }

    @Test
    func testStagedDockerfileArtifactsAppendHiddenDirectoryToIgnoreFile() throws {
        let artifacts = Application.BuildCommand.stagedDockerfileArtifacts(
            buildFileData: Data("FROM scratch\n".utf8),
            ignoreFileData: Data("node_modules".utf8)
        )

        let staged = try #require(artifacts)
        #expect(staged.hiddenDockerDir == ".com.apple.container.dockerfiles")
        #expect(String(decoding: staged.dockerfileData, as: UTF8.self) == "FROM scratch\n")
        #expect(
            String(decoding: staged.ignoreFileData, as: UTF8.self)
                == "node_modules\n.com.apple.container.dockerfiles\n"
        )
    }
}
