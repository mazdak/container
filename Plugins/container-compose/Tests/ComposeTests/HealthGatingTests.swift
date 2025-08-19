//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
//===----------------------------------------------------------------------===//

import Testing
import Logging
@testable import ComposeCore

struct HealthGatingTests {
    let log = Logger(label: "test")

    func makeProject(health: Bool) -> Project {
        let h = health ? HealthCheck(test: ["/bin/true"]) : nil
        let db = Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: h, deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        let web = Service(name: "web", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: ["db"], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_web", profiles: [], labels: [:], cpus: nil, memory: nil)
        return Project(name: "p", services: ["db": db, "web": web], networks: [:], volumes: [:])
    }

    @Test
    func testAwaitHealthyReturnsWhenHealthy() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: true)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
    }

    @Test
    func testAwaitHealthyWaitsUntilNotified() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: true)
        // Don't set healthy yet; flip after a short delay
        async let gate: Void = orch.awaitServiceHealthy(project: project, serviceName: "db", deadlineSeconds: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        _ = try await gate
    }

    @Test
    func testAwaitHealthyNoHealthcheckDoesNotBlock() async throws {
        let orch = Orchestrator(log: log)
        // Project with db lacking healthcheck
        let p = Project(name: "p", services: [
            "db": Service(name: "db", image: "img", command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: ["default"], dependsOn: [], dependsOnHealthy: [], healthCheck: nil, deploy: nil, restart: nil, containerName: "p_db", profiles: [], labels: [:], cpus: nil, memory: nil)
        ], networks: [:], volumes: [:])
        try await orch.awaitServiceHealthy(project: p, serviceName: "db", deadlineSeconds: 1)
    }


    @Test
    func testAwaitStartedReturnsWhenRunning() async throws {
        let orch = Orchestrator(log: log)
        let project = makeProject(health: false)
        await orch.testSetServiceHealthy(project: project, serviceName: "db")
        try await orch.awaitServiceStarted(project: project, serviceName: "db", deadlineSeconds: 1)
    }

    @Test
    func testAwaitCompletedPlaceholder() throws {
        // Placeholder: without runtime or a direct setter to stopped, we acknowledge coverage gap here.
        #expect(true)
    }
}

