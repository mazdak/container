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

import Foundation
import Testing

@testable import ComposePlugin

@Suite(.serialized)
struct ComposeCLITests {
    @Test
    func testComposeHelpListsSubcommands() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try ComposeCLITestSupport.run(arguments: ["--help"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Manage multi-container applications"))
        #expect(result.stdout.contains("up"))
        #expect(result.stdout.contains("health"))
        #expect(result.stdout.contains("validate"))
    }

    @Test
    func testValidatePrintsSummary() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        version: '3'
        services:
          web:
            image: nginx:alpine
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["validate", "-f", composeURL.path], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Compose file is valid"))
        #expect(result.stdout.contains("Services: 1"))
        #expect(result.stdout.contains("- web"))
    }

    @Test
    func testValidateQuietSuppressesOutput() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          web:
            image: nginx:alpine
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["validate", "-f", composeURL.path, "--quiet"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test
    func testUpEarlyExitForUnmatchedProfiles() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          web:
            image: nginx:alpine
            profiles: [prod]
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["up", "-f", composeURL.path, "--profile", "dev"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("No services matched the provided filters. Nothing to start."))
        #expect(result.stdout.contains("Profiles: dev"))
    }

    @Test
    func testStartEarlyExitForUnmatchedProfiles() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          api:
            image: nginx:alpine
            profiles: [prod]
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["start", "-f", composeURL.path, "--profile", "dev"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Nothing to start."))
    }

    @Test
    func testStopEarlyExitForUnmatchedProfiles() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          api:
            image: nginx:alpine
            profiles: [prod]
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["stop", "-f", composeURL.path, "--profile", "dev"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Nothing to stop."))
    }

    @Test
    func testRestartEarlyExitForUnmatchedProfiles() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          api:
            image: nginx:alpine
            profiles: [prod]
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["restart", "-f", composeURL.path, "--profile", "dev"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("Nothing to restart."))
    }

    @Test
    func testHealthWithoutHealthChecks() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          app:
            image: nginx:alpine
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["health", "-f", composeURL.path], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.contains("No services with health checks found"))
    }

    @Test
    func testHealthQuietWithoutHealthChecksExitsZero() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          app:
            image: nginx:alpine
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["health", "-f", composeURL.path, "--quiet"], currentDirectory: dir)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }

    @Test
    func testExecRejectsUnknownServiceBeforeRuntimeAccess() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let composeURL = dir.appendingPathComponent("docker-compose.yml")
        try """
        services:
          app:
            image: nginx:alpine
        """.write(to: composeURL, atomically: true, encoding: .utf8)

        let result = try ComposeCLITestSupport.run(arguments: ["exec", "-f", composeURL.path, "missing", "pwd"], currentDirectory: dir)
        #expect(result.status != 0)
        #expect(result.stderr.contains("Service 'missing' not found or not enabled by active profiles"))
    }

    @Test
    func testCommandHelpCoversRuntimeCommands() throws {
        let dir = try ComposeCLITestSupport.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let commands = [
            ("down", "Stop and remove containers"),
            ("ps", "List containers"),
            ("logs", "View output from containers"),
            ("rm", "Remove stopped containers"),
            ("exec", "Execute a command in a running container"),
        ]

        for (command, expected) in commands {
            let result = try ComposeCLITestSupport.run(arguments: [command, "--help"], currentDirectory: dir)
            #expect(result.status == 0)
            #expect(result.stdout.contains(expected))
        }
    }

}
