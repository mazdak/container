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

import ComposeCore
import Foundation
import Testing
#if os(macOS)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized)
struct ProgressStubTests {
    @Test
    func testProgressBarLifecycleMessagesAndHandler() async throws {
        let output = try await captureStandardOutput {
            let config = try ProgressConfig(description: "Testing progress", showTasks: false, showItems: true)
            #expect(config.description == "Testing progress")
            #expect(config.showTasks == false)
            #expect(config.showItems == true)

            let progress = ProgressBar(config: config)
            progress.start()
            await progress.handler([.setTasks(1), .custom("noop")])
            progress.finish()
            progress.finish()
        }

        #expect(output.contains("Testing progress...\n"))
        #expect(output.contains("✓ Testing progress complete\n"))
        #expect(output.components(separatedBy: "✓ Testing progress complete\n").count == 2)
    }
}

private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
    let pipe = Pipe()
    let stdoutFD = FileHandle.standardOutput.fileDescriptor
    let savedStdoutFD = dup(stdoutFD)
    precondition(savedStdoutFD != -1, "failed to duplicate stdout")

    var restored = false
    func restore() {
        guard !restored else { return }
        restored = true
        fflush(stdout)
        dup2(savedStdoutFD, stdoutFD)
        close(savedStdoutFD)
        pipe.fileHandleForWriting.closeFile()
    }

    fflush(stdout)
    dup2(pipe.fileHandleForWriting.fileDescriptor, stdoutFD)

    do {
        try await body()
        restore()
    } catch {
        restore()
        throw error
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    pipe.fileHandleForReading.closeFile()
    return String(data: data, encoding: .utf8) ?? ""
}
