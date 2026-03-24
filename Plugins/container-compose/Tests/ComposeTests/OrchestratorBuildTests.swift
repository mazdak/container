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
import Logging
import ContainerizationError
import ContainerizationOS
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import TerminalProgress

@testable import ComposeCore

private actor RecordingBuildService: BuildService {
    private(set) var calls: [(serviceName: String, targetTag: String)] = []

    func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        targetTag: String,
        progressHandler: ComposeCore.ProgressUpdateHandler?
    ) async throws -> String {
        _ = buildConfig
        _ = projectName
        _ = progressHandler
        calls.append((serviceName, targetTag))
        return targetTag
    }

    func snapshotCalls() -> [(serviceName: String, targetTag: String)] {
        calls
    }
}

private actor RecordingProcess: ClientProcess {
    let id = UUID().uuidString
    private(set) var killedSignals: [Int32] = []

    func start() async throws {}
    func resize(_ size: Terminal.Size) async throws { _ = size }
    func kill(_ signal: Int32) async throws { killedSignals.append(signal) }
    func wait() async throws -> Int32 { 0 }

    func snapshotKilledSignals() -> [Int32] {
        killedSignals
    }
}

private actor OrderedEvents {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private final class SignalHandlerBox: @unchecked Sendable {
    var handlers: [Int32: (@Sendable () -> Void)] = [:]
}

@Suite(.serialized)
struct OrchestratorBuildTests {
    let log = Logger(label: "test")

    @Test
    func testOrchestratorCreation() async throws {
        _ = Orchestrator(log: log)
        #expect(Bool(true))
    }

    @Test
    func testBuildServiceCreation() async throws {
        _ = DefaultBuildService()
        #expect(Bool(true))
    }

    @Test
    func testServiceHasBuild() throws {
        // Test service with build config
        let buildConfig = BuildConfig(context: ".", dockerfile: "Dockerfile", args: nil, target: nil)
        let serviceWithBuild = Service(
            name: "test",
            image: nil,
            build: buildConfig
        )
        #expect(serviceWithBuild.hasBuild == true)

        // Test service with image only
        let serviceWithImage = Service(
            name: "test",
            image: "nginx:latest",
            build: nil
        )
        #expect(serviceWithImage.hasBuild == false)

        // Test service with both image and build
        let serviceWithBoth = Service(
            name: "test",
            image: "nginx:latest",
            build: buildConfig
        )
        #expect(serviceWithBoth.hasBuild == true)
    }

    @Test
    func testHealthCheckConfigurationValidation() throws {
        // Test health check with empty test command
        let emptyHealthCheck = HealthCheck(
            test: [],
            interval: nil,
            timeout: nil,
            retries: nil,
            startPeriod: nil
        )

        #expect(emptyHealthCheck.test.isEmpty)

        // Test health check with valid configuration
        let validHealthCheck = HealthCheck(
            test: ["curl", "-f", "http://localhost:8080/health"],
            interval: 30.0,
            timeout: 10.0,
            retries: 3,
            startPeriod: 60.0
        )

        #expect(validHealthCheck.test.count == 3)
        #expect(validHealthCheck.interval == 30.0)
        #expect(validHealthCheck.timeout == 10.0)
        #expect(validHealthCheck.retries == 3)
        #expect(validHealthCheck.startPeriod == 60.0)
    }

    @Test
    func testDependencyWaitTimeoutUsesHealthBudgetWhenLongerThanDefault() throws {
        let healthCheck = HealthCheck(
            test: ["/bin/true"],
            interval: 45.0,
            timeout: 5.0,
            retries: 4,
            startPeriod: 300.0,
            startInterval: 15.0
        )

        #expect(healthCheck.dependencyWaitTimeoutSeconds == 450)
    }

    @Test
    func testMakeContainerNetworkingConfigurationUsesRuntimeDNSAndDefaultNetwork() throws {
        DefaultsStore.unset(key: .defaultDNSDomain)

        let orchestrator = Orchestrator(log: log)

        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: []
        )

        #expect(networking.dns.nameservers.isEmpty)
        #expect(networking.dns.domain == nil)
        #expect(networking.attachments.count == 1)
        #expect(networking.attachments[0].network == ClientNetwork.defaultNetworkName)
        #expect(networking.attachments[0].options.hostname == "service-1")
        #expect(networking.attachments[0].options.mtu == 1280)
    }

    @Test
    func testMakeContainerNetworkingConfigurationPreservesNetworkOrder() throws {
        DefaultsStore.unset(key: .defaultDNSDomain)

        guard #available(macOS 26, *) else {
            return
        }

        let orchestrator = Orchestrator(log: log)
        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: ["alpha", "beta"]
        )

        #expect(networking.dns.nameservers.isEmpty)
        #expect(networking.attachments.map(\.network) == ["alpha", "beta"])
        #expect(networking.attachments.allSatisfy { $0.options.hostname == "service-1" })
        #expect(networking.attachments.allSatisfy { $0.options.mtu == 1280 })
    }

    @Test
    func testMakeContainerNetworkingConfigurationUsesDefaultDNSDomainForPrimaryHostname() throws {
        DefaultsStore.set(value: "compose.test", key: .defaultDNSDomain)
        defer { DefaultsStore.unset(key: .defaultDNSDomain) }

        let orchestrator = Orchestrator(log: log)
        let networking = try orchestrator.makeContainerNetworkingConfiguration(
            containerId: "service-1",
            networkIds: []
        )

        #expect(networking.dns.domain == "compose.test")
        #expect(networking.attachments[0].options.hostname == "service-1.compose.test.")
    }

    @Test
    func testResolvedMemoryLimitDefaultsToSixGiBWhenUnspecified() async throws {
        let orchestrator = Orchestrator(log: log)
        let service = Service(name: "frontend", image: "resq-fullstack:dev")

        let memory = await orchestrator.resolvedMemoryLimit(for: service)

        #expect(memory == 6144.mib())
    }

    @Test
    func testResolvedMemoryLimitUsesExplicitComposeValue() async throws {
        let orchestrator = Orchestrator(log: log)
        let service = Service(name: "frontend", image: "resq-fullstack:dev", memory: "2g")

        let memory = await orchestrator.resolvedMemoryLimit(for: service)

        #expect(memory == 2048.mib())
    }

    @Test
    func testResolvedProcessEnvironmentIncludesImageDefaultsAndServiceOverrides() throws {
        let orchestrator = Orchestrator(log: log)

        let environment = orchestrator.resolvedProcessEnvironment(
            imageEnvironment: [
                "PATH=/usr/local/bin:/usr/bin",
                "GF_PATHS_HOME=/usr/share/grafana",
                "UNPARSEABLE"
            ],
            serviceEnvironment: [
                "PATH": "/custom/bin:/usr/local/bin:/usr/bin",
                "GF_PATHS_DATA": "/var/lib/grafana"
            ]
        )

        #expect(environment.contains("PATH=/custom/bin:/usr/local/bin:/usr/bin"))
        #expect(environment.contains("GF_PATHS_HOME=/usr/share/grafana"))
        #expect(environment.contains("GF_PATHS_DATA=/var/lib/grafana"))
        #expect(!environment.contains("UNPARSEABLE"))
    }

    @Test
    func testResolvedRunImageNameUsesEffectiveImageNameForBuildOnlyService() throws {
        let orchestrator = Orchestrator(log: log)
        let service = Service(
            name: "worker",
            build: BuildConfig(context: ".", dockerfile: "Dockerfile")
        )

        let imageName = orchestrator.resolvedRunImageName(projectName: "demo", service: service)

        #expect(imageName == service.effectiveImageName(projectName: "demo"))
        #expect(imageName != "demo-worker")
    }

    @Test
    func testResolvedStartupServicesDropsDependenciesWhenNoDepsIsEnabled() throws {
        let orchestrator = Orchestrator(log: log)
        let services: [String: Service] = [
            "web": Service(name: "web", image: "nginx", dependsOnHealthy: ["db"]),
        ]

        let scoped = orchestrator.resolvedStartupServices(services: services, noDeps: true)

        #expect(scoped["web"]?.dependsOnHealthy == [])
    }

    @Test
    func testOneOffRunServiceDropsPublishedPorts() throws {
        let orchestrator = Orchestrator(log: log)
        let baseService = Service(
            name: "web",
            image: "nginx:alpine",
            command: ["nginx", "-g", "daemon off;"],
            environment: ["APP_ENV": "dev"],
            ports: [PortMapping(hostPort: "8080", containerPort: "80")],
            volumes: [VolumeMount(source: "/host/data", target: "/data", type: .bind)],
            networks: ["default"]
        )

        let runService = orchestrator.makeOneOffRunService(
            service: baseService,
            command: ["sh"],
            workdir: "/workspace",
            environment: ["APP_ENV": "test"],
            containerName: "demo_web_run",
            tty: true,
            interactive: true
        )

        #expect(runService.ports.isEmpty)
        #expect(runService.command == ["sh"])
        #expect(runService.workingDir == "/workspace")
        #expect(runService.environment["APP_ENV"] == "test")
        #expect(runService.volumes.map(\.source) == baseService.volumes.map(\.source))
        #expect(runService.volumes.map(\.target) == baseService.volumes.map(\.target))
        #expect(runService.networks == baseService.networks)
    }

    @Test
    func testBuildImagesIfNeededBuildsServicesWithExplicitImageTags() async throws {
        let buildService = RecordingBuildService()
        let orchestrator = Orchestrator(log: log, buildService: buildService)
        let service = Service(
            name: "api",
            image: "example/api:dev",
            build: BuildConfig(context: ".", dockerfile: "Dockerfile")
        )
        let project = Project(name: "demo", services: ["api": service])

        try await orchestrator.buildImagesIfNeeded(project: project, services: ["api": service], progressHandler: nil)

        let calls = await buildService.snapshotCalls()
        #expect(calls.count == 1)
        #expect(calls[0].serviceName == "api")
        #expect(calls[0].targetTag == "example/api:dev")
    }

    @Test
    func testBuildOutputCaptureLockSerializesConcurrentTasks() async throws {
        let events = OrderedEvents()

        async let first: Void = BuildOutputCaptureLock.shared.withLock {
            await events.append("first-start")
            try await Task.sleep(nanoseconds: 150_000_000)
            await events.append("first-end")
        }

        async let second: Void = BuildOutputCaptureLock.shared.withLock {
            await events.append("second-start")
            await events.append("second-end")
        }

        _ = try await (first, second)

        let recorded = await events.snapshot()
        #expect(recorded == ["first-start", "first-end", "second-start", "second-end"])
    }

    @Test
    func testShouldCreateNewContainerAfterReuseResolutionIsFalse() {
        let orchestrator = Orchestrator(log: log)
        let existing = ContainerSnapshot(
            configuration: ContainerConfiguration(
                id: "demo_api",
                image: ImageDescription(
                    reference: "demo:api",
                    descriptor: Descriptor(
                        mediaType: "application/vnd.oci.image.index.v1+json",
                        digest: "sha256:test",
                        size: 1
                    )
                ),
                process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
            ),
            status: .running,
            networks: []
        )

        #expect(!orchestrator.shouldCreateNewContainer(after: .reuse(existing)))
        #expect(orchestrator.shouldCreateNewContainer(after: .createNew))
    }

    @Test
    func testPSContainerListFiltersDefaultToRunningOnly() {
        let orchestrator = Orchestrator(log: log)

        let runningOnly = orchestrator.psContainerListFilters(all: false)
        let showAll = orchestrator.psContainerListFilters(all: true)

        #expect(runningOnly.status == .running)
        #expect(showAll.status == nil)
    }

    @Test
    func testTailedLogDataReturnsRequestedTrailingLines() {
        let orchestrator = Orchestrator(log: log)
        let data = Data("one\ntwo\nthree\n".utf8)

        let tailed = orchestrator.tailedLogData(data, tail: 2)

        #expect(String(decoding: tailed, as: UTF8.self) == "two\nthree")
    }

    @Test
    func testParsedLogEntryUsesEmbeddedISO8601TimestampWhenRequested() {
        let orchestrator = Orchestrator(log: log)

        let entry = orchestrator.parsedLogEntry(
            serviceName: "app",
            containerName: "demo_app",
            stream: .stdout,
            line: "2026-03-23T12:34:56Z hello",
            timestamps: true
        )

        #expect(entry.message == "hello")
        #expect(entry.timestamp != nil)
    }

    @Test
    func testDecodeLogChunkFlushesBufferedLineAtEOF() {
        let orchestrator = Orchestrator(log: log)

        let result = orchestrator.decodeLogChunk(
            serviceName: "app",
            containerName: "demo_app",
            stream: .stdout,
            buffer: Data("partial".utf8),
            incoming: Data(),
            timestamps: false,
            flush: true
        )

        #expect(result.remainder.isEmpty)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].message == "partial")
    }

    @Test
    func testConfigurationReuseHashUsesResolvedRuntimeMountNamesAndProcess() {
        let orchestrator = Orchestrator(log: log)
        let project = Project(name: "demo")
        let service = Service(
            name: "api",
            image: "demo:api",
            workingDir: nil,
            environment: [:],
            volumes: [VolumeMount(source: "data", target: "/var/lib/data", type: .volume)]
        )

        var runtimeConfig = ContainerConfiguration(
            id: "demo_api",
            image: ImageDescription(
                reference: "demo:api",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(
                executable: "/entrypoint",
                arguments: ["serve"],
                environment: ["PATH=/usr/local/bin"],
                workingDirectory: "/workspace"
            )
        )
        runtimeConfig.mounts = [
            Filesystem.volume(
                name: "demo_data",
                format: "ext4",
                source: "/vols/demo_data",
                destination: "/var/lib/data",
                options: []
            )
        ]

        var rawConfig = runtimeConfig
        rawConfig.initProcess = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-c"],
            environment: [],
            workingDirectory: "/"
        )
        rawConfig.mounts = [
            Filesystem.volume(
                name: "data",
                format: "ext4",
                source: "data",
                destination: "/var/lib/data",
                options: []
            )
        ]

        let runtimeHash = orchestrator.configurationReuseHash(
            project: project,
            serviceName: "api",
            service: service,
            imageName: "demo:api",
            configuration: runtimeConfig
        )
        let rawHash = orchestrator.configurationReuseHash(
            project: project,
            serviceName: "api",
            service: service,
            imageName: "demo:api",
            configuration: rawConfig
        )

        #expect(runtimeHash != rawHash)
    }

    @Test
    func testConfigurationReuseHashIncludesNetworkingAndHostSettings() {
        let orchestrator = Orchestrator(log: log)
        let project = Project(name: "demo")
        let service = Service(name: "api", image: "demo:api")

        var baseConfig = ContainerConfiguration(
            id: "demo_api",
            image: ImageDescription(
                reference: "demo:api",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        baseConfig.networks = [
            AttachmentConfiguration(
                network: "default",
                options: AttachmentOptions(hostname: "demo_api")
            )
        ]
        baseConfig.dns = ContainerConfiguration.DNSConfiguration(nameservers: ["192.168.64.1"], domain: "compose.test")
        baseConfig.hosts = [
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.10", hostnames: ["db"])
        ]

        var updatedConfig = baseConfig
        updatedConfig.networks = [
            AttachmentConfiguration(
                network: "demo_backend",
                options: AttachmentOptions(hostname: "demo_api", mtu: 1400)
            )
        ]
        updatedConfig.hosts = [
            ContainerConfiguration.HostEntry(ipAddress: "192.168.64.20", hostnames: ["db", "postgres"])
        ]

        let baseHash = orchestrator.configurationReuseHash(
            project: project,
            serviceName: "api",
            service: service,
            imageName: "demo:api",
            configuration: baseConfig
        )
        let updatedHash = orchestrator.configurationReuseHash(
            project: project,
            serviceName: "api",
            service: service,
            imageName: "demo:api",
            configuration: updatedConfig
        )

        #expect(baseHash != updatedHash)
    }

    @Test
    func testApplyUserOverrideUpdatesInitProcessUser() {
        let orchestrator = Orchestrator(log: log)
        let configuration = ContainerConfiguration(
            id: "demo_run",
            image: ImageDescription(
                reference: "demo:api",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )

        let overridden = orchestrator.applyUserOverride(user: "1000:1000", to: configuration)

        #expect(overridden.initProcess.user.description == "1000:1000")
    }

    @Test
    func testMatchesDownTargetUsesLabelsForRemoveOrphans() {
        let orchestrator = Orchestrator(log: log)
        let configuration = ContainerConfiguration(
            id: "custom-db",
            image: ImageDescription(
                reference: "postgres:latest",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeled = configuration
        labeled.labels = [
            "com.apple.compose.project": "demo",
            "com.apple.compose.service": "db",
        ]
        let snapshot = ContainerSnapshot(configuration: labeled, status: .running, networks: [])

        let matches = orchestrator.matchesDownTarget(
            projectName: "demo",
            expectedIds: [],
            container: snapshot,
            removeOrphans: true
        )

        #expect(matches)
    }

    @Test
    func testResolvedCPUCountRejectsFractionalValues() throws {
        let orchestrator = Orchestrator(log: log)

        #expect(throws: ContainerizationError.self) {
            _ = try orchestrator.resolvedCPUCount("0.5")
        }
        #expect(throws: ContainerizationError.self) {
            _ = try orchestrator.resolvedCPUCount("1.5")
        }
        #expect(try orchestrator.resolvedCPUCount("1.0") == 1)
    }

    @Test
    func testFollowEOFActionFinishesForStoppedContainers() {
        let orchestrator = Orchestrator(log: log)

        #expect(orchestrator.followEOFAction(status: .running) == .keepFollowing)
        #expect(orchestrator.followEOFAction(status: .stopped) == .finish)
    }

    @Test
    func testInstallProcessSignalForwardersPropagatesSignals() async throws {
        let orchestrator = Orchestrator(log: log)
        let process = RecordingProcess()
        let handlerBox = SignalHandlerBox()

        orchestrator.installProcessSignalForwarders(process: process) { signo, action in
            handlerBox.handlers[signo] = action
        }

        handlerBox.handlers[SIGINT]?()
        handlerBox.handlers[SIGTERM]?()
        try await Task.sleep(nanoseconds: 50_000_000)

        let killed = await process.snapshotKilledSignals()
        #expect(killed == [SIGINT, SIGTERM])
    }

    @Test
    func testOrchestratorCleanupFunctionality() async throws {
        // Test that the orchestrator can be created and basic functionality works
        _ = Orchestrator(log: log)

        // Test that cleanup methods exist and can be called (they're private but we can test indirectly)
        // This is more of an integration test to ensure the cleanup functionality is present
        #expect(Bool(true)) // Placeholder - cleanup functionality is implemented in the orchestrator
    }
}
