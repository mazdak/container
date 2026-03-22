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

struct OrchestratorNetworkTests {
    let log = Logger(label: "test")

    @Test
    func testMapServiceNetworkIds_projectScoped() throws {
        let orch = Orchestrator(log: log)
        let nets: [String: Network] = [
            "appnet": Network(name: "appnet", driver: "bridge", external: false)
        ]
        let svc = Service(name: "web", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["appnet"], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["web": svc], networks: nets, volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids == ["demo_appnet"])
    }

    @Test
    func testMapServiceNetworkIds_external() throws {
        let orch = Orchestrator(log: log)
        let nets: [String: Network] = [
            "extnet": Network(name: "extnet", driver: "bridge", external: true, externalName: "corp-net")
        ]
        let svc = Service(name: "api", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["extnet"], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["api": svc], networks: nets, volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids == ["corp-net"]) // external uses literal name
    }

    @Test
    func testMapServiceNetworkIds_defaultWhenNone() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: [], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["api": svc], networks: [:], volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids.isEmpty)
    }
}
