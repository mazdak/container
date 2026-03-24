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
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerResource
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
    func testMapServiceNetworkIds_usesCustomNonExternalName() throws {
        let orch = Orchestrator(log: log)
        let nets: [String: Network] = [
            "default": Network(name: "default", driver: "bridge", external: false, externalName: "corp-net")
        ]
        let svc = Service(name: "api", image: "alpine", networks: ["default"])
        let proj = Project(name: "demo", services: ["api": svc], networks: nets, volumes: [:])

        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)

        #expect(ids == ["corp-net"])
    }

    @Test
    func testMapServiceNetworkIds_defaultWhenNone() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", build: nil, command: nil, entrypoint: nil, workingDir: nil, environment: [:], ports: [], volumes: [], networks: [], dependsOn: [], dependsOnHealthy: [], dependsOnStarted: [], dependsOnCompletedSuccessfully: [], healthCheck: nil, deploy: nil, restart: nil, containerName: nil, profiles: [], labels: [:], cpus: nil, memory: nil, tty: false, stdinOpen: false)
        let proj = Project(name: "demo", services: ["api": svc], networks: [:], volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids.isEmpty)
    }

    @Test
    func testMapServiceNetworkIds_bridgeNetworkModeUsesRuntimeDefault() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", networks: ["default"], networkMode: "bridge")
        let proj = Project(name: "demo", services: ["api": svc], networks: ["default": Network(name: "default", driver: "bridge", external: false)], volumes: [:])
        let ids = try orch.mapServiceNetworkIds(project: proj, service: svc)
        #expect(ids.isEmpty)
    }

    @Test
    func testMapServiceNetworkIdsRejectsUnsupportedNetworkMode() {
        let orch = Orchestrator(log: log)
        let svc = Service(name: "api", image: "alpine", networkMode: "host")
        let proj = Project(name: "demo", services: ["api": svc], networks: [:], volumes: [:])

        #expect(throws: ContainerizationError.self) {
            _ = try orch.mapServiceNetworkIds(project: proj, service: svc)
        }
    }

    @Test
    func testResolvedAttachmentNetworkIdsAddsDefaultForHostGatewayServices() throws {
        let orch = Orchestrator(log: log)
        let svc = Service(
            name: "api",
            image: "alpine",
            networks: ["appnet"],
            extraHosts: [ExtraHost(hostname: "host.docker.internal", address: "host-gateway")]
        )
        let proj = Project(
            name: "demo",
            services: ["api": svc],
            networks: ["appnet": Network(name: "appnet", driver: "bridge", external: false)],
            volumes: [:]
        )

        let ids = try orch.resolvedAttachmentNetworkIds(project: proj, service: svc)
        #expect(ids == ["default", "demo_appnet"])
    }

    @Test
    func testComposePeerHostsIncludesServiceNameAndAliases() throws {
        let orch = Orchestrator(log: log)
        let backend = Service(
            name: "backend",
            image: "demo:dev",
            networks: ["resq-network"],
            extraHosts: [ExtraHost(hostname: "host.docker.internal", address: "host-gateway")]
        )
        let localstack = Service(
            name: "aws",
            image: "localstack/localstack:latest",
            networks: ["resq-network"],
            networkAliases: ["resq-network": ["localstack"]]
        )
        let project = Project(
            name: "resq-fullstack",
            services: ["backend": backend, "aws": localstack],
            networks: ["resq-network": Network(name: "resq-network", driver: "bridge", external: false)],
            volumes: [:]
        )

        let localstackConfig = ContainerConfiguration(
            id: "resq-localstack",
            image: ImageDescription(
                reference: "docker.io/localstack/localstack:4.2",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeledConfig = localstackConfig
        labeledConfig.labels = [
            "com.apple.compose.project": "resq-fullstack",
            "com.apple.compose.service": "aws",
        ]

        let localstackSnapshot = ContainerSnapshot(
            configuration: labeledConfig,
            status: .running,
            networks: [
                Attachment(
                    network: "resq-fullstack_resq-network",
                    hostname: "resq-localstack",
                    ipv4Address: try CIDRv4("192.168.66.27/24"),
                    ipv4Gateway: try IPv4Address("192.168.66.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "backend",
            service: backend,
            containers: [localstackSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.27",
                hostnames: ["aws", "localstack"]
            )
        ])
    }

    @Test
    func testComposePeerHostsUsesImplicitDefaultNetwork() throws {
        let orch = Orchestrator(log: log)
        let app = Service(name: "app", image: "demo:app")
        let db = Service(name: "db", image: "postgres:16")
        let project = Project(
            name: "demo",
            services: ["app": app, "db": db],
            networks: ["default": Network(name: "default", driver: "bridge", external: false)],
            volumes: [:]
        )

        let dbConfig = ContainerConfiguration(
            id: "demo_db",
            image: ImageDescription(
                reference: "postgres:16",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeled = dbConfig
        labeled.labels = [
            "com.apple.compose.project": "demo",
            "com.apple.compose.service": "db",
        ]

        let dbSnapshot = ContainerSnapshot(
            configuration: labeled,
            status: .running,
            networks: [
                Attachment(
                    network: "default",
                    hostname: "demo_db",
                    ipv4Address: try CIDRv4("192.168.68.12/24"),
                    ipv4Gateway: try IPv4Address("192.168.68.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "app",
            service: app,
            containers: [dbSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.68.12",
                hostnames: ["db"]
            )
        ])
    }

    @Test
    func testComposePeerHostsIncludesAliasesFromEverySharedNetwork() throws {
        let orch = Orchestrator(log: log)
        let backend = Service(
            name: "backend",
            image: "demo:dev",
            networks: ["frontend", "backend"]
        )
        let api = Service(
            name: "api",
            image: "demo:dev",
            networks: ["frontend", "backend"],
            networkAliases: [
                "frontend": ["public-api"],
                "backend": ["internal-api"],
            ]
        )
        let project = Project(
            name: "demo",
            services: ["backend": backend, "api": api],
            networks: [
                "frontend": Network(name: "frontend", driver: "bridge", external: false),
                "backend": Network(name: "backend", driver: "bridge", external: false),
            ],
            volumes: [:]
        )

        let apiConfig = ContainerConfiguration(
            id: "demo-api",
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
        var labeled = apiConfig
        labeled.labels = [
            "com.apple.compose.project": "demo",
            "com.apple.compose.service": "api",
        ]

        let apiSnapshot = ContainerSnapshot(
            configuration: labeled,
            status: .running,
            networks: [
                Attachment(
                    network: "demo_frontend",
                    hostname: "demo-api",
                    ipv4Address: try CIDRv4("192.168.80.10/24"),
                    ipv4Gateway: try IPv4Address("192.168.80.1"),
                    ipv6Address: nil,
                    macAddress: nil
                ),
                Attachment(
                    network: "demo_backend",
                    hostname: "demo-api",
                    ipv4Address: try CIDRv4("192.168.81.10/24"),
                    ipv4Gateway: try IPv4Address("192.168.81.1"),
                    ipv6Address: nil,
                    macAddress: nil
                ),
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "backend",
            service: backend,
            containers: [apiSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.80.10",
                hostnames: ["api", "public-api"]
            ),
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.81.10",
                hostnames: ["api", "internal-api"]
            ),
        ])
    }

    @Test
    func testPlannedComposeNetworkAttachmentsIncludeImplicitDefaultNetwork() throws {
        let orch = Orchestrator(log: log)
        let service = Service(name: "db", image: "postgres:16")
        let project = Project(
            name: "demo",
            services: ["db": service],
            networks: ["default": Network(name: "default", driver: "bridge", external: false)],
            volumes: [:]
        )

        let attachments = try orch.plannedComposeNetworkAttachments(
            project: project,
            serviceName: "db",
            service: service
        )

        #expect(attachments.keys.sorted() == ["default"])
        #expect(attachments["default"]?.network == "default")
        #expect(attachments["default"]?.options.hostname == "demo_db")
    }

    @Test
    func testComposePeerHostsIncludesPlannedStartupPeers() {
        let orch = Orchestrator(log: log)

        let hosts = orch.composePeerHosts(
            plannedAttachments: [
                Orchestrator.ComposePeerAttachment(
                    serviceName: "aws",
                    networkName: "resq-network",
                    ipAddress: "192.168.66.27",
                    aliases: ["localstack"]
                ),
                Orchestrator.ComposePeerAttachment(
                    serviceName: "postgres",
                    networkName: "resq-network",
                    ipAddress: "192.168.66.39",
                    aliases: []
                ),
            ]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.27",
                hostnames: ["aws", "localstack"]
            ),
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.39",
                hostnames: ["postgres"]
            ),
        ])
    }

    @Test
    func testComposePeerHostsIncludesRunningSharedServiceOutsideCurrentProjectModel() throws {
        let orch = Orchestrator(log: log)
        let backend = Service(
            name: "backend",
            image: "demo:dev",
            networks: ["resq-network"]
        )
        let project = Project(
            name: "resq-fullstack",
            services: ["backend": backend],
            networks: ["resq-network": Network(name: "resq-network", driver: "bridge", external: false)],
            volumes: [:]
        )

        let postgresConfig = ContainerConfiguration(
            id: "resq-postgres",
            image: ImageDescription(
                reference: "docker.io/kartoza/postgis:17-3.5",
                descriptor: Descriptor(
                    mediaType: "application/vnd.oci.image.index.v1+json",
                    digest: "sha256:test",
                    size: 1
                )
            ),
            process: ProcessConfiguration(executable: "/bin/sh", arguments: [], environment: [])
        )
        var labeledConfig = postgresConfig
        labeledConfig.labels = [
            "com.apple.compose.project": "resq-fullstack",
            "com.apple.compose.service": "postgres",
        ]

        let postgresSnapshot = ContainerSnapshot(
            configuration: labeledConfig,
            status: .running,
            networks: [
                Attachment(
                    network: "resq-fullstack_resq-network",
                    hostname: "resq-postgres",
                    ipv4Address: try CIDRv4("192.168.66.39/24"),
                    ipv4Gateway: try IPv4Address("192.168.66.1"),
                    ipv6Address: nil,
                    macAddress: nil
                )
            ]
        )

        let hosts = try orch.composePeerHosts(
            project: project,
            serviceName: "backend",
            service: backend,
            containers: [postgresSnapshot]
        )

        #expect(hosts == [
            ContainerConfiguration.HostEntry(
                ipAddress: "192.168.66.39",
                hostnames: ["postgres"]
            )
        ])
    }
}
