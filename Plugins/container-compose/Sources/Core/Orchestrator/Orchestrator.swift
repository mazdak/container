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

import ArgumentParser
import Foundation
import ContainerNetworkService
import ContainerNetworkServiceClient
import CryptoKit
import ContainerAPIClient
import ContainerCommands
import ContainerPersistence
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOS
import ContainerizationOCI
import Logging

#if os(macOS)
import Darwin
#else
import Glibc
#endif

// Keep strong references to DispatchSourceSignal for exec signal forwarding
@MainActor
fileprivate final class ExecSignalRetainer {
    private static var sources: [DispatchSourceSignal] = []
    static func retain(_ src: DispatchSourceSignal) { sources.append(src) }
}

actor BuildOutputCaptureLock {
    static let shared = BuildOutputCaptureLock()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        guard locked else {
            locked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

// MARK: - HealthCheckRunner



public protocol HealthCheckRunner: Sendable {
    func execute(containerId: String, healthCheck: HealthCheck, log: Logger) async -> Bool
}

public struct DefaultHealthCheckRunner: HealthCheckRunner {
    public init() {}

    public func execute(containerId: String, healthCheck: HealthCheck, log: Logger) async -> Bool {
        guard !healthCheck.test.isEmpty else {
            log.warning("Health check has no test command")
            return false
        }

        do {
            let processId = "healthcheck-\(UUID().uuidString)"
            let containerClient = ContainerClient()

            // Create process configuration
            let procConfig = ProcessConfiguration(
                executable: healthCheck.test[0],
                arguments: Array(healthCheck.test.dropFirst()),
                environment: [], // Use container's environment
                workingDirectory: "/"
            )

            let process = try await containerClient.createProcess(
                containerId: containerId,
                processId: processId,
                configuration: procConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()

            let result = try await waitForHealthCheckExit(
                process: process,
                timeout: healthCheck.timeout
            )

            // Check exit status
            let success = result == 0
            if success {
                log.debug("Health check passed for container")
            } else {
                log.warning("Health check failed with exit code \(result)")
            }

            return success
        } catch let error as TimeoutError {
            log.warning("Health check timed out after \(error.duration)s")
            return false
        } catch {
            log.error("Health check execution failed: \(error.localizedDescription)")
            return false
        }
    }

    struct TimeoutError: Error {
        let duration: TimeInterval
    }

    internal func waitForHealthCheckExit(
        process: any ClientProcess,
        timeout: TimeInterval?
    ) async throws -> Int32 {
        guard let timeout, timeout > 0 else {
            return try await process.wait()
        }

        enum WaitOutcome {
            case exited(Int32)
            case timedOut
        }

        return try await withThrowingTaskGroup(of: WaitOutcome.self) { group in
            group.addTask {
                .exited(try await process.wait())
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw ContainerizationError(.internalError, message: "health check wait did not produce a result")
            }

            switch first {
            case .exited(let exitCode):
                group.cancelAll()
                return exitCode
            case .timedOut:
                try? await process.kill(SIGKILL)
                while let outcome = try await group.next() {
                    if case .exited = outcome {
                        break
                    }
                }
                throw TimeoutError(duration: timeout)
            }
        }
    }
}

// MARK: - BuildService

public protocol BuildService: Sendable {
    func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String
}

public struct DefaultBuildService: BuildService {
    private let log: Logger

    public init() {
        self.log = Logger(label: "DefaultBuildService")
    }

    public func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String {
        do {
            // Validate build configuration
            let contextDir = buildConfig.context ?? "."
            let dockerfilePathRaw = buildConfig.dockerfile ?? "Dockerfile"

            // Check if dockerfile exists
            // Resolve dockerfile relative to context if needed
            let dockerfileURL: URL = {
                let url = URL(fileURLWithPath: dockerfilePathRaw)
                if url.path.hasPrefix("/") { return url }
                return URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfilePathRaw)
            }()
            guard FileManager.default.fileExists(atPath: dockerfileURL.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "Dockerfile not found at path '\(dockerfileURL.path)' for service '\(serviceName)'"
                )
            }

            // Check if context directory exists
            let contextURL = URL(fileURLWithPath: contextDir)
            guard FileManager.default.fileExists(atPath: contextURL.path) else {
                throw ContainerizationError(
                    .notFound,
                    message: "Build context directory not found at path '\(contextDir)' for service '\(serviceName)'"
                )
            }

            try await runBuildCommand(
                serviceName: serviceName,
                buildConfig: buildConfig,
                imageName: targetTag,
                contextURL: contextURL,
                dockerfileURL: dockerfileURL,
                progressHandler: progressHandler
            )

            log.info("Successfully built image \(targetTag) for service \(serviceName)")
            return targetTag

        } catch let error as ContainerizationError {
            // Re-throw ContainerizationErrors as-is
            throw error
        } catch {
            log.error("Failed to build image for service \(serviceName): \(error)")
            throw ContainerizationError(
                .internalError,
                message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
            )
        }
    }

    private func runBuildCommand(
        serviceName: String,
        buildConfig: BuildConfig,
        imageName: String,
        contextURL: URL,
        dockerfileURL: URL,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        var arguments: [String] = []
        let dockerfilePath = dockerfileURL.path(percentEncoded: false)
        if dockerfilePath != "Dockerfile" {
            arguments.append(contentsOf: ["--file", dockerfilePath])
        }
        if let args = buildConfig.args {
            for key in args.keys.sorted() {
                if let value = args[key] {
                    arguments.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
                }
            }
        }
        if let target = buildConfig.target, !target.isEmpty {
            arguments.append(contentsOf: ["--target", target])
        }
        arguments.append(contentsOf: ["--tag", imageName])
        arguments.append(contentsOf: ["--progress", "plain"])
        arguments.append(contextURL.path(percentEncoded: false))

        var command = try ContainerCommands.Application.BuildCommand.parse(arguments)
        try command.validate()

        guard let handler = progressHandler else {
            do {
                try await command.run()
            } catch {
                throw ContainerizationError(
                    .internalError,
                    message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
                )
            }
            return
        }

        await handler([
            .setDescription("Building \(serviceName)"),
            .setSubDescription("Context: \(contextURL.path(percentEncoded: false))"),
            .setTotalTasks(1),
            .setTasks(0)
        ])

        func forwardOutput(from handle: FileHandle, prefix: String) -> Task<Void, Never> {
            Task {
                var buffer = Data()
                do {
                    for try await byte in handle.bytes {
                        if byte == 0x0A {
                            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                                let events = progressEvents(for: line)
                                if !events.isEmpty {
                                    await handler(events)
                                }
                            }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                        let events = progressEvents(for: line)
                        if !events.isEmpty {
                            await handler(events)
                        }
                    }
                } catch {
                    await handler([.custom("\(prefix) stream error: \(error.localizedDescription)")])
                }
            }
        }

        func progressEvents(for line: String) -> [ProgressUpdateEvent] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            var events: [ProgressUpdateEvent] = [.setSubDescription(trimmed)]

            if trimmed.localizedCaseInsensitiveContains("error") || trimmed.localizedCaseInsensitiveContains("failed") {
                events.append(.custom("⚠️ \(trimmed)"))
            } else if trimmed.localizedCaseInsensitiveContains("done") || trimmed.localizedCaseInsensitiveContains("completed") {
                events.append(.custom("✅ \(trimmed)"))
            } else {
                events.append(.custom(trimmed))
            }

            return events
        }

        try await BuildOutputCaptureLock.shared.withLock {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            let stdoutFD = FileHandle.standardOutput.fileDescriptor
            let stderrFD = FileHandle.standardError.fileDescriptor

            let stdoutBackup = dup(stdoutFD)
            let stderrBackup = dup(stderrFD)

            guard stdoutBackup != -1, stderrBackup != -1 else {
                throw ContainerizationError(
                    .internalError,
                    message: "Failed to duplicate standard IO descriptors for build"
                )
            }

            fflush(stdout)
            fflush(stderr)

            dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, stdoutFD)
            dup2(stderrPipe.fileHandleForWriting.fileDescriptor, stderrFD)

            let stdoutTask = forwardOutput(from: stdoutPipe.fileHandleForReading, prefix: "build")
            let stderrTask = forwardOutput(from: stderrPipe.fileHandleForReading, prefix: "build")

            var encounteredError: Error?
            do {
                try await command.run()
            } catch {
                encounteredError = error
            }

            fflush(stdout)
            fflush(stderr)

            dup2(stdoutBackup, stdoutFD)
            dup2(stderrBackup, stderrFD)
            close(stdoutBackup)
            close(stderrBackup)

            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()

            await stdoutTask.value
            await stderrTask.value

            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()

            if let error = encounteredError {
                await handler([
                    .custom("Build failed for \(serviceName): \(error.localizedDescription)")
                ])
                throw ContainerizationError(
                    .internalError,
                    message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
                )
            }

            await handler([
                .setSubDescription("Built image \(imageName)"),
                .addTasks(1),
                .custom("Build completed for \(serviceName)")
            ])
        }
    }
}

// MARK: - VolumeClient (injectable for tests)

public protocol VolumeClient: Sendable {
    func create(name: String, driver: String, driverOpts: [String: String], labels: [String: String]) async throws -> ContainerResource.Volume
    func delete(name: String) async throws
    func list() async throws -> [ContainerResource.Volume]
    func inspect(name: String) async throws -> ContainerResource.Volume
}

public struct DefaultVolumeClient: VolumeClient {
    public init() {}
    public func create(name: String, driver: String, driverOpts: [String : String], labels: [String : String]) async throws -> ContainerResource.Volume {
        try await ClientVolume.create(name: name, driver: driver, driverOpts: driverOpts, labels: labels)
    }
    public func delete(name: String) async throws {
        try await ClientVolume.delete(name: name)
    }
    public func list() async throws -> [ContainerResource.Volume] {
        try await ClientVolume.list()
    }
    public func inspect(name: String) async throws -> ContainerResource.Volume {
        try await ClientVolume.inspect(name)
    }
}

public protocol VolumePopulator: Sendable {
    func populateIfNeeded(
        volume: ContainerResource.Volume,
        mount: VolumeMount,
        imageName: String,
        project: Project,
        serviceName: String,
        log: Logger
    ) async throws
}

public struct DefaultVolumePopulator: VolumePopulator {
    private static let helperImageReference = "docker.io/library/alpine:3.20"
    private static let helperSourceMount = "/__compose_image"
    private static let helperVolumeMount = "/__compose_volume"

    private let containerClient: ContainerClient

    public init(containerClient: ContainerClient = ContainerClient()) {
        self.containerClient = containerClient
    }

    public func populateIfNeeded(
        volume: ContainerResource.Volume,
        mount: VolumeMount,
        imageName: String,
        project: Project,
        serviceName: String,
        log: Logger
    ) async throws {
        guard mount.type == .volume else {
            return
        }

        let helperImage = try await ensureHelperImageAvailable()
        let serviceImage = try await ClientImage.get(reference: imageName)
        let snapshot = try await serviceImage.getCreateSnapshot(platform: .current)
        let helperId = "compose-copyup-\(UUID().uuidString.lowercased())"
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        var sourceMount = snapshot
        sourceMount.destination = Self.helperSourceMount
        sourceMount.options = ["ro"]

        let targetMount = Filesystem.volume(
            name: volume.name,
            format: volume.format,
            source: volume.source,
            destination: Self.helperVolumeMount,
            options: []
        )

        let copyScript = """
        set -eu
        src="\(Self.helperSourceMount)${COPYUP_SOURCE_PATH}"
        dst="\(Self.helperVolumeMount)"
        mkdir -p "$dst"
        if [ ! -e "$src" ]; then
          exit 0
        fi
        if find "$dst" -mindepth 1 ! -name lost+found -print -quit | grep -q .; then
          exit 0
        fi
        if [ -d "$src" ]; then
          cp -a "$src"/. "$dst"/
        else
          cp -a "$src" "$dst"/
        fi
        """

        let process = ProcessConfiguration(
            executable: "/bin/sh",
            arguments: ["-lc", copyScript],
            environment: ["COPYUP_SOURCE_PATH=\(mount.target)"],
            workingDirectory: "/"
        )

        var config = ContainerConfiguration(id: helperId, image: helperImage.description, process: process)
        config.mounts = [sourceMount, targetMount]
        config.resources.cpus = 1
        config.resources.memoryInBytes = 256.mib()
        config.labels = [
            "com.apple.compose.project": project.name,
            "com.apple.compose.service": serviceName,
            "com.apple.compose.helper": "volume-copyup",
            "com.apple.compose.target": mount.target,
        ]

        do {
            try await containerClient.create(
                configuration: config,
                options: ContainerCreateOptions(autoRemove: true),
                kernel: kernel
            )
            let helperProcess = try await containerClient.bootstrap(id: helperId, stdio: [nil, nil, nil])
            try await helperProcess.start()
            let exitCode = try await helperProcess.wait()
            guard exitCode == 0 else {
                throw ContainerizationError(
                    .internalError,
                    message: "failed to populate volume '\(volume.name)' for target '\(mount.target)' from image '\(imageName)'"
                )
            }
        } catch {
            try? await containerClient.delete(id: helperId, force: true)
            throw error
        }

        log.debug("Ensured compose volume copy-up state", metadata: [
            "volume": "\(volume.name)",
            "target": "\(mount.target)",
            "service": "\(serviceName)",
        ])
    }

    private func ensureHelperImageAvailable() async throws -> ClientImage {
        do {
            return try await ClientImage.get(reference: Self.helperImageReference)
        } catch {
            return try await ClientImage.fetch(reference: Self.helperImageReference, platform: .current)
        }
    }
}

// MARK: - Orchestrator

/// The main orchestrator for managing containerized applications
///
/// The Orchestrator is responsible for coordinating all aspects of container
/// lifecycle management, including service orchestration, image building,
/// health monitoring, and dependency resolution.
///
/// ## Key Features
///
/// - **Dependency Management**: Starts and stops services in the correct order
/// - **Image Building**: Automatically builds Docker images for services with build configs
/// - **Health Monitoring**: Executes health checks and waits for services to be ready
/// - **Parallel Execution**: Builds images concurrently where possible to improve performance
/// - **Caching**: Reuses previously built images when build configurations haven't changed
///
/// ## Thread Safety
///
/// All operations are thread-safe through the actor model, allowing multiple
/// concurrent operations while maintaining data consistency.
///
/// ## Example Usage
///
/// ```swift
/// let orchestrator = Orchestrator(log: logger)
/// let project = try await converter.convert(composeFile: composeFile, ...)
///
/// try await orchestrator.up(
///     project: project,
///     services: ["web", "api"],
///     detach: true
/// )
/// ```
public actor Orchestrator {
    public enum PullPolicy: String, Sendable {
        case always
        case missing
        case never
    }
    private let log: Logger
    private let containerClient: ContainerClient
    private var projectState: [String: ProjectState] = [:]
    private var healthWaiters: [String: [String: [CheckedContinuation<Void, Error>]]] = [:]
    private var healthMonitors: [String: [String: Task<Void, Never>]] = [:]
    private let healthRunner: HealthCheckRunner
    private let buildService: BuildService
    private let volumeClient: VolumeClient
    private let volumePopulator: VolumePopulator
    private var buildCache: [String: String] = [:] // Cache key -> image name
    private var activeStartupServices: [String: Service] = [:]
    private var composeHostReservations: [String: Set<ComposeHostReservation>] = [:]

    /// State of a project
    private struct ProjectState {
        var containers: [String: ContainerState] = [:]
        var lastAccessed: Date = Date()
    }

    /// Container status
    private enum ContainerStatus {
        case created
        case starting
        case healthy
        case unhealthy
        case stopped
        case removed
    }

    /// State of a container in a project
    private struct ContainerState {
        let serviceName: String
        let containerID: String
        let containerName: String
        var status: ContainerStatus
    }

    private struct ComposeHostReservation: Hashable, Sendable {
        let networkId: String
        let hostname: String
        let plugin: String
    }

    internal struct ComposePeerAttachment: Sendable {
        let serviceName: String
        let networkName: String
        let ipAddress: String
        let aliases: [String]
    }

    enum ExistingContainerResolution {
        case createNew
        case reuse(ContainerSnapshot)
    }

    /// Service status information
    public struct ServiceStatus: Sendable {
        public let name: String
        public let containerID: String
        public let containerName: String
        public let status: String
        public let ports: String
        public let image: String

        public init(name: String, containerID: String, containerName: String, status: String, ports: String, image: String) {
            self.name = name
            self.containerID = containerID
            self.containerName = containerName
            self.status = status
            self.ports = ports
            self.image = image
        }
    }

    public struct DownResult: Sendable {
        public let removedContainers: [String]
        public let removedVolumes: [String]
        public init(removedContainers: [String], removedVolumes: [String]) {
            self.removedContainers = removedContainers
            self.removedVolumes = removedVolumes
        }
    }

    /// Log entry information
    public struct LogEntry: Sendable {
        public let serviceName: String
        public let containerName: String
        public let message: String
        public let stream: LogStream
        public let timestamp: Date?

        public enum LogStream: Sendable {
            case stdout
            case stderr
        }

        public init(serviceName: String, containerName: String, message: String, stream: LogStream, timestamp: Date? = nil) {
            self.serviceName = serviceName
            self.containerName = containerName
            self.message = message
            self.stream = stream
            self.timestamp = timestamp
        }
    }

    public init(
        log: Logger,
        healthRunner: HealthCheckRunner = DefaultHealthCheckRunner(),
        buildService: BuildService? = nil,
        volumeClient: VolumeClient = DefaultVolumeClient(),
        volumePopulator: VolumePopulator = DefaultVolumePopulator()
    ) {
        self.log = log
        self.containerClient = ContainerClient()
        self.healthRunner = healthRunner
        self.buildService = buildService ?? DefaultBuildService()
        self.volumeClient = volumeClient
        self.volumePopulator = volumePopulator
    }

    /// Start services in a project.
    ///
    /// Services are started in dependency order, with independent services
    /// starting in parallel. Existing containers may be reused or recreated
    /// based on the provided options.
    ///
    /// - Parameters:
    ///   - project: The project containing service definitions
    ///   - services: Specific services to start (empty means all)
    ///   - detach: Whether to run containers in the background
    ///   - forceRecreate: Force recreation of existing containers
    ///   - noRecreate: Never recreate existing containers
    ///   - removeOnExit: Automatically remove containers when they exit
    ///   - progressHandler: Optional handler for progress updates
    /// - Throws: `ContainerizationError` if service configuration is invalid or container operations fail
    public func up(
        project: Project,
        services: [String] = [],
        detach: Bool = false,
        forceRecreate: Bool = false,
        noRecreate: Bool = false,
        noDeps: Bool = false,
        removeOrphans: Bool = false,
        removeOnExit: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil,
        pullPolicy: PullPolicy = .missing,
        wait: Bool = false,
        waitTimeoutSeconds: Int? = nil,
        disableHealthcheck: Bool = false
    ) async throws {
        log.info("Starting project '\(project.name)'")

        // Filter services based on selection and --no-deps
        let targetServices: [String: Service]
        if services.isEmpty {
            targetServices = project.services
        } else if noDeps {
            // Only start the explicitly named services
            targetServices = project.services.filter { services.contains($0.key) }
        } else {
            // Include dependencies
            targetServices = DependencyResolver.filterWithDependencies(services: project.services, selected: services)
        }

        // Ensure compose networks (macOS 26+) exist before starting services
        try await ensureComposeNetworks(project: project)

        // Build images for services that need building
        do {
            log.info("Checking if images need to be built for \(targetServices.count) services")
            for (name, service) in targetServices {
                log.info("Service '\(name)': hasBuild=\(service.hasBuild), image=\(service.image ?? "nil"), build=\(service.build != nil ? "present" : "nil")")
            }

            try await buildImagesIfNeeded(
                project: project,
                services: targetServices,
                progressHandler: progressHandler
            )
            log.info("Image building completed")
        } catch {
            log.error("Failed to build images: \(error)")
            // Clean up any partial state
            projectState[project.name] = nil
            throw error
        }

        // Initialize project state
        if projectState[project.name] == nil {
            projectState[project.name] = ProjectState()
        } else {
            // Update access time for existing project
            updateProjectAccess(projectName: project.name)
        }

        // Optionally remove orphans by inspecting runtime containers
        if removeOrphans {
            await removeOrphanContainers(project: project)
        }

        // Create and start containers for services
        do {
            try await createAndStartContainers(
                project: project,
                services: targetServices,
                detach: detach,
                forceRecreate: forceRecreate,
                noRecreate: noRecreate,
                noDeps: noDeps,
                removeOnExit: removeOnExit,
                progressHandler: progressHandler,
                pullPolicy: pullPolicy,
                disableHealthcheck: disableHealthcheck
            )
        } catch {
            await releaseTrackedComposeHostReservations()
            activeStartupServices = [:]
            throw error
        }
        activeStartupServices = [:]
        composeHostReservations = [:]

        // If --wait is set, wait for selected services to be healthy/running
        if wait {
            let timeout = waitTimeoutSeconds ?? 300
            for (name, svc) in targetServices {
                if !disableHealthcheck, svc.healthCheck != nil {
                    try await waitUntilHealthy(project: project, serviceName: name, service: svc, timeoutSeconds: timeout)
                } else {
                    let cid = svc.containerName ?? "\(project.name)_\(name)"
                    try await waitUntilContainerRunning(containerId: cid, timeoutSeconds: timeout)
                }
            }
        }

        // Clean up old project states to prevent memory leaks
        cleanupOldProjectStates()

        log.info("Project '\(project.name)' started successfully")
    }



    /// Clean up old project states to prevent memory leaks
    private func cleanupOldProjectStates() {
        let cutoffDate = Date().addingTimeInterval(-3600) // 1 hour ago
        let oldProjects = projectState.filter { $0.value.lastAccessed < cutoffDate }

        for (projectName, _) in oldProjects {
            log.info("Cleaning up old project state for '\(projectName)'")
            projectState[projectName] = nil
        }

        if !oldProjects.isEmpty {
            log.info("Cleaned up \(oldProjects.count) old project states")
        }
    }

    /// Update last accessed time for a project
    private func updateProjectAccess(projectName: String) {
        if var state = projectState[projectName] {
            state.lastAccessed = Date()
            projectState[projectName] = state
        }
    }

    /// Remove named volumes for a project
    private func removeNamedVolumes(project: Project, progressHandler: ProgressUpdateHandler?) async {
        // Implementation for removing named volumes
        // This would need to be implemented based on the volume management system
        log.info("Volume removal not yet implemented for project '\(project.name)'")
    }



    /// Cancel health monitors for a project
    private func cancelHealthMonitors(projectName: String) {
        guard let map = healthMonitors[projectName] else { return }
        for (_, task) in map { task.cancel() }
        healthMonitors[projectName] = [:]
    }

    /// Create and start containers for services
    private func createAndStartContainers(
        project: Project,
        services: [String: Service],
        detach: Bool,
        forceRecreate: Bool,
        noRecreate: Bool,
        noDeps: Bool,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?,
        pullPolicy: PullPolicy,
        disableHealthcheck: Bool
    ) async throws {
        let startupServices = resolvedStartupServices(services: services, noDeps: noDeps)
        activeStartupServices = startupServices

        let plannedNetworkRefreshServices = try await plannedComposeNetworkRefreshServices(
            project: project,
            services: startupServices,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate
        )
        for serviceName in plannedNetworkRefreshServices.sorted() {
            guard let service = startupServices[serviceName] else { continue }
            let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
            guard let existing = try? await findRuntimeContainer(byId: containerId) else { continue }
            try await deleteExistingContainer(
                projectName: project.name,
                serviceName: serviceName,
                existing: existing
            )
        }

        // Sort services by dependencies
        let resolution = try DependencyResolver.resolve(services: startupServices)
        let sortedServices = resolution.startOrder

        for serviceName in sortedServices {
            guard let service = startupServices[serviceName] else { continue }

            do {
                // Wait for dependency conditions before starting this service
                try await waitForDependencyConditions(project: project, serviceName: serviceName, services: startupServices, disableHealthcheck: disableHealthcheck)

                try await createAndStartContainer(
                    project: project,
                    serviceName: serviceName,
                    service: service,
                    detach: detach,
                    forceRecreate: forceRecreate || plannedNetworkRefreshServices.contains(serviceName),
                    noRecreate: noRecreate,
                    removeOnExit: removeOnExit,
                    progressHandler: progressHandler,
                    pullPolicy: pullPolicy
                )

                // Do not run background health probes by default.
                // Health checks are evaluated only when --wait is explicitly requested.
            } catch {
                log.error("Failed to start service '\(serviceName)': \(error)")
                throw error
            }
        }
    }

    nonisolated internal func resolvedStartupServices(services: [String: Service], noDeps: Bool) -> [String: Service] {
        guard noDeps else { return services }
        return DependencyResolver.scopeToSelection(services: services)
    }

    private func plannedComposeNetworkRefreshServices(
        project: Project,
        services: [String: Service],
        forceRecreate: Bool,
        noRecreate: Bool
    ) async throws -> Set<String> {
        guard !noRecreate else {
            return []
        }

        var refreshSeeds = Set<String>()
        if forceRecreate {
            refreshSeeds.formUnion(
                services.compactMap { name, service in
                    composeNetworkNames(for: service).isEmpty ? nil : name
                }
            )
        }

        for (serviceName, service) in services where !composeNetworkNames(for: service).isEmpty {
            let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
            guard let existing = try? await findRuntimeContainer(byId: containerId) else {
                refreshSeeds.insert(serviceName)
                continue
            }

            guard !forceRecreate else { continue }

            let imageName = service.effectiveImageName(projectName: project.name)
            let currentHash = existing.configuration.labels["com.apple.container.compose.config-hash"]
            do {
                let expectedHash = try await expectedConfigurationHash(
                    project: project,
                    serviceName: serviceName,
                    service: service,
                    imageName: imageName,
                    removeOnExit: false
                )
                if currentHash != expectedHash {
                    refreshSeeds.insert(serviceName)
                }
            } catch {
                refreshSeeds.insert(serviceName)
            }
        }

        return expandedComposeNetworkRefreshServices(
            services: services,
            seeds: refreshSeeds
        )
    }

    nonisolated internal func expandedComposeNetworkRefreshServices(
        services: [String: Service],
        seeds: Set<String>
    ) -> Set<String> {
        guard !seeds.isEmpty else {
            return []
        }

        var expanded = seeds
        var pending = Array(seeds)

        while let current = pending.popLast() {
            guard let service = services[current] else {
                continue
            }
            let currentNetworks = Set(composeNetworkNames(for: service))
            guard !currentNetworks.isEmpty else {
                continue
            }
            for (peerName, peerService) in services where !expanded.contains(peerName) {
                guard !currentNetworks.isDisjoint(with: Set(composeNetworkNames(for: peerService))) else {
                    continue
                }
                expanded.insert(peerName)
                pending.append(peerName)
            }
        }

        return expanded
    }

    /// Wait for dependencies according to compose depends_on conditions
    private func waitForDependencyConditions(project: Project, serviceName: String, services: [String: Service], disableHealthcheck: Bool) async throws {
        guard let svc = services[serviceName] else { return }

        // Wait for service_started
        for dep in svc.dependsOnStarted {
            let depId = services[dep]?.containerName ?? "\(project.name)_\(dep)"
            let timeout = services[dep]?.healthCheck?.dependencyWaitTimeoutSeconds ?? 120
            try await waitUntilContainerRunning(containerId: depId, timeoutSeconds: timeout)
        }
        // Wait for service_healthy
        for dep in svc.dependsOnHealthy where !disableHealthcheck {
            if let depSvc = services[dep] {
                try await waitUntilHealthy(
                    project: project,
                    serviceName: dep,
                    service: depSvc,
                    timeoutSeconds: depSvc.healthCheck?.dependencyWaitTimeoutSeconds
                )
            }
        }
        if !svc.dependsOnCompletedSuccessfully.isEmpty {
            throw ContainerizationError(
                .unsupported,
                message: "depends_on.condition=service_completed_successfully is not supported by the current compose plugin because the runtime API does not expose container exit status"
            )
        }
    }

    private func waitUntilContainerRunning(containerId: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            do {
                let all = try await containerClient.list()
                if let c = all.first(where: { $0.id == containerId }), c.status == .running {
                    return
                }
            } catch { /* ignore */ }
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        }
        throw ContainerizationError(.timeout, message: "Timed out waiting for container \(containerId) to start")
    }

    private func waitUntilContainerStopped(containerId: String, timeoutSeconds: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            do {
                let all = try await containerClient.list()
                if let c = all.first(where: { $0.id == containerId }) {
                    if c.status != .running { return }
                } else {
                    return
                }
            } catch { /* ignore */ }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ContainerizationError(.timeout, message: "Timed out waiting for container \(containerId) to stop")
    }

    private func runHealthCheckOnce(project: Project, serviceName: String, service: Service) async throws -> Bool {
        guard let hc = service.healthCheck else { return true }
        let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
        return await healthRunner.execute(containerId: containerId, healthCheck: hc, log: log)
    }

    private func waitUntilHealthy(project: Project, serviceName: String, service: Service, timeoutSeconds: Int? = nil) async throws {
        guard let hc = service.healthCheck else { return }
        let steadyInterval = max(hc.interval ?? 5.0, 0.1)
        let startupInterval = max(hc.startInterval ?? steadyInterval, 0.1)
        let retries = max(1, hc.retries ?? 10)
        let startPeriodDeadline = Date().addingTimeInterval(max(hc.startPeriod ?? 0, 0))
        let deadline = timeoutSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }

        var failuresAfterStartPeriod = 0
        while true {
            if let deadline, deadline.timeIntervalSinceNow <= 0 {
                throw ContainerizationError(.timeout, message: "Service \(serviceName) did not become healthy in time")
            }

            if try await runHealthCheckOnce(project: project, serviceName: serviceName, service: service) {
                return
            }

            let withinStartPeriod = Date() < startPeriodDeadline
            if !withinStartPeriod {
                failuresAfterStartPeriod += 1
                if failuresAfterStartPeriod >= retries {
                    throw ContainerizationError(.timeout, message: "Service \(serviceName) did not become healthy in time")
                }
            }

            let nextInterval = withinStartPeriod ? startupInterval : steadyInterval
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    throw ContainerizationError(.timeout, message: "Service \(serviceName) did not become healthy in time")
                }
                try await Task.sleep(nanoseconds: UInt64(min(nextInterval, remaining) * 1_000_000_000))
            } else {
                try await Task.sleep(nanoseconds: UInt64(nextInterval * 1_000_000_000))
            }
        }
    }

    /// Create and start a single container for a service
    private func createAndStartContainer(
        project: Project,
        serviceName: String,
        service: Service,
        detach: Bool,
        forceRecreate: Bool,
        noRecreate: Bool,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?,
        pullPolicy: PullPolicy
    ) async throws {
        log.info("Starting service '\(serviceName)' with image '\(service.effectiveImageName(projectName: project.name))', hasBuild: \(service.hasBuild)")

        let containerId = service.containerName ?? "\(project.name)_\(serviceName)"

        // Handle existing container logic
        let existingResolution = try await handleExistingContainer(
            project: project,
            serviceName: serviceName,
            service: service,
            containerId: containerId,
            forceRecreate: forceRecreate,
            noRecreate: noRecreate
        )

        switch existingResolution {
        case .reuse(let existing):
            try await reuseExistingContainer(
                project: project,
                serviceName: serviceName,
                service: service,
                containerId: containerId,
                existing: existing
            )
            consumeTrackedComposeHostReservations(for: serviceName)
            return
        case .createNew:
            break
        }

        // Ensure image is available for build services
        let imageName = service.effectiveImageName(projectName: project.name)
        try await ensureImageAvailable(serviceName: serviceName, service: service, imageName: imageName, policy: pullPolicy)

        // Create and start new container
        try await createAndStartNewContainer(
            project: project,
            serviceName: serviceName,
            service: service,
            containerId: containerId,
            imageName: imageName,
            removeOnExit: removeOnExit,
            progressHandler: progressHandler
        )
        consumeTrackedComposeHostReservations(for: serviceName)
    }

    /// Handle existing container logic (reuse, recreate, or skip)
    private func handleExistingContainer(
        project: Project,
        serviceName: String,
        service: Service,
        containerId: String,
        forceRecreate: Bool,
        noRecreate: Bool
    ) async throws -> ExistingContainerResolution {
        guard let existing = try? await findRuntimeContainer(byId: containerId) else {
            return .createNew
        }

        if noRecreate {
            log.info("Reusing existing container '\(existing.id)' for service '\(serviceName)' (no-recreate)")
            return .reuse(existing)
        }

        if !forceRecreate {
            // Check if configuration has changed
            let imageName = service.effectiveImageName(projectName: project.name)
            let currentHash = existing.configuration.labels["com.apple.container.compose.config-hash"]
            do {
                let expectedHash = try await expectedConfigurationHash(
                    project: project,
                    serviceName: serviceName,
                    service: service,
                    imageName: imageName,
                    removeOnExit: false
                )
                if currentHash == expectedHash {
                    log.info("Reusing existing container '\(existing.id)' for service '\(serviceName)' (config unchanged)")
                    return .reuse(existing)
                }
            } catch {
                log.warning("Failed to compute reuse hash for service '\(serviceName)'; recreating container: \(error)")
            }
        }

        try await deleteExistingContainer(
            projectName: project.name,
            serviceName: serviceName,
            existing: existing
        )
        return .createNew
    }

    private func deleteExistingContainer(
        projectName: String,
        serviceName: String,
        existing: ContainerSnapshot
    ) async throws {
        log.info("Recreating existing container '\(existing.id)' for service '\(serviceName)'")
        do {
            try await containerClient.stop(id: existing.id, opts: ContainerStopOptions(timeoutInSeconds: 15, signal: SIGTERM))
        } catch {
            log.warning("failed to stop \(existing.id): \(error)")
        }
        do {
            try await waitUntilContainerStopped(containerId: existing.id, timeoutSeconds: 20)
        } catch {
            log.warning("timeout waiting for \(existing.id) to stop: \(error); sending SIGKILL")
            do {
                try await containerClient.kill(id: existing.id, signal: SIGKILL)
            } catch {
                log.warning("failed to SIGKILL \(existing.id): \(error)")
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        do {
            try await containerClient.delete(id: existing.id)
        } catch {
            log.warning("failed to delete \(existing.id): \(error); retrying forced delete after short delay")
            try? await Task.sleep(nanoseconds: 700_000_000)
            do {
                try await containerClient.delete(id: existing.id, force: true)
            } catch {
                log.warning("forced delete attempt failed for \(existing.id): \(error)")
            }
        }
        projectState[projectName]?.containers.removeValue(forKey: serviceName)
    }

    private func trackComposeHostReservation(
        serviceName: String,
        networkId: String,
        hostname: String,
        plugin: String
    ) {
        composeHostReservations[serviceName, default: []].insert(
            ComposeHostReservation(
                networkId: networkId,
                hostname: hostname,
                plugin: plugin
            )
        )
    }

    private func consumeTrackedComposeHostReservations(for serviceName: String) {
        composeHostReservations.removeValue(forKey: serviceName)
    }

    private func releaseTrackedComposeHostReservations() async {
        let reservations = composeHostReservations
        composeHostReservations = [:]

        for reservation in reservations.values.flatMap({ $0 }) {
            let client = NetworkClient(id: reservation.networkId, plugin: reservation.plugin)
            try? await client.deallocate(hostname: reservation.hostname)
        }
    }

    private func reuseExistingContainer(
        project: Project,
        serviceName: String,
        service: Service,
        containerId: String,
        existing: ContainerSnapshot
    ) async throws {
        projectState[project.name]?.containers[serviceName] = ContainerState(
            serviceName: serviceName,
            containerID: existing.id,
            containerName: containerId,
            status: existing.status == .running ? .starting : .stopped
        )

        guard existing.status != .running else {
            return
        }

        for mount in existing.configuration.mounts where mount.isVirtiofs {
            if !FileManager.default.fileExists(atPath: mount.source) {
                throw ContainerizationError(.invalidState, message: "path '\(mount.source)' is not a directory")
            }
        }

        let initProcess = try await containerClient.bootstrap(id: existing.id, stdio: [nil, nil, nil])
        try await initProcess.start()
        projectState[project.name]?.containers[serviceName]?.status = .starting
    }

    nonisolated internal func shouldCreateNewContainer(after resolution: ExistingContainerResolution) -> Bool {
        if case .createNew = resolution {
            return true
        }
        return false
    }

    /// Ensure the image is available for services that need building
    private func ensureImageAvailable(serviceName: String, service: Service, imageName: String, policy: PullPolicy) async throws {
        if service.hasBuild {
            log.info("Service '\(serviceName)' needs building, ensuring image is available")
            do { _ = try await ClientImage.get(reference: imageName) } catch {
                log.error("Built image '\(imageName)' not found for service '\(serviceName)': \(error)")
                throw ContainerizationError(
                    .notFound,
                    message: "Built image '\(imageName)' not found for service '\(serviceName)'. Build may have failed."
                )
            }
        } else if let imageRef = service.image {
            // Fetch image if missing
            switch policy {
            case .always:
                _ = try await ClientImage.fetch(reference: imageRef, platform: .current)
                log.info("Pulled image: \(imageRef)")
            case .missing:
                do { _ = try await ClientImage.get(reference: imageRef) }
                catch { _ = try await ClientImage.fetch(reference: imageRef, platform: .current) }
            case .never:
                _ = try await ClientImage.get(reference: imageRef)
            }
        }
    }

    /// Create and start a new container for the service
    private func createAndStartNewContainer(
        project: Project,
        serviceName: String,
        service: Service,
        containerId: String,
        imageName: String,
        removeOnExit: Bool,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Get the default kernel
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        // Create container configuration
        let containerConfig = try await createContainerConfiguration(
            project: project,
            serviceName: serviceName,
            service: service,
            imageName: imageName,
            removeOnExit: removeOnExit
        )

        // Create the container
        let createOptions = ContainerCreateOptions(autoRemove: removeOnExit)
        try await containerClient.create(
            configuration: containerConfig,
            options: createOptions,
            kernel: kernel
        )
        let container = try await containerClient.get(id: containerConfig.id)

        // Store container state
        projectState[project.name]?.containers[serviceName] = ContainerState(
            serviceName: serviceName,
            containerID: container.id,
            containerName: containerId,
            status: .created
        )

        // Bootstrap the sandbox (set up VM and agent) and then start the init process
        let initProcess = try await containerClient.bootstrap(id: container.id, stdio: [nil, nil, nil])
        try await initProcess.start()

        // Update container state
        projectState[project.name]?.containers[serviceName]?.status = .starting

        log.info("Started service '\(serviceName)' with container '\(container.id)'")
    }

    private func findRuntimeContainer(byId id: String) async throws -> ContainerSnapshot? {
        let all = try await containerClient.list()
        return all.first { $0.id == id }
    }

    private func expectedContainerIds(for project: Project) -> Set<String> {
        Set(project.services.map { name, svc in svc.containerName ?? "\(project.name)_\(name)" })
    }

    private func removeOrphanContainers(project: Project) async {
        do {
            let expectedServices = Set(project.services.keys)
            let all = try await containerClient.list()
            let orphans = all.filter { c in
                // Prefer labels if present
                if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                    let svc = c.configuration.labels["com.apple.compose.service"] ?? ""
                    return !expectedServices.contains(svc)
                }
                // Fallback: prefix-based
                let prefix = "\(project.name)_"
                let id = c.id
                if id.hasPrefix(prefix) {
                    let svc = String(id.dropFirst(prefix.count))
                    return !expectedServices.contains(svc)
                }
                return false
            }
            for c in orphans {
                log.info("Removing orphan container '\(c.id)'")
                try? await containerClient.stop(id: c.id)
                try? await containerClient.delete(id: c.id)
            }
        } catch {
            log.warning("Failed to evaluate/remove orphans: \(error)")
        }
    }

    /// Create container configuration for a service
    private func createContainerConfiguration(
        project: Project,
        serviceName: String,
        service: Service,
        imageName: String,
        removeOnExit: Bool
    ) async throws -> ContainerConfiguration {
        // Resolve the image to get the proper ImageDescription
        let clientImage = try await ClientImage.get(reference: imageName)
        let imageDescription = clientImage.description

        // Compose entrypoint/command precedence using image config as base
        let imageObj = try? await clientImage.config(for: .current)
        let imageConfig = imageObj?.config
        let imageEntrypoint: [String] = imageConfig?.entrypoint ?? []
        let imageCmd: [String] = imageConfig?.cmd ?? []
        let svcEntrypoint = service.entrypoint
        let svcCommand = service.command

        func resolveProcessCommand() -> [String] {
            var entry: [String] = []
            var cmd: [String] = []
            if service.entrypointCleared {
                entry = []
            } else if let svcEntrypoint {
                entry = svcEntrypoint
            } else if !imageEntrypoint.isEmpty {
                entry = imageEntrypoint
            }
            if service.commandCleared {
                cmd = []
            } else if let svcCommand {
                cmd = svcCommand
            } else if !imageCmd.isEmpty {
                cmd = imageCmd
            }
            return entry + cmd
        }

        let finalArgs = resolveProcessCommand()
        let execPath = finalArgs.first ?? "/bin/sh"
        let execArgs = Array(finalArgs.dropFirst())
        let processEnvironment = resolvedProcessEnvironment(
            imageEnvironment: imageConfig?.env ?? [],
            serviceEnvironment: service.environment
        )

        // Create process configuration
        let processConfig = ProcessConfiguration(
            executable: execPath,
            arguments: execArgs,
            environment: processEnvironment,
            workingDirectory: service.workingDir ?? (imageConfig?.workingDir ?? "/"),
            terminal: service.tty
        )

        // Create container configuration
        var config = ContainerConfiguration(
            id: service.containerName ?? "\(project.name)_\(serviceName)",
            image: imageDescription,
            process: processConfig
        )

        // Add labels (merge user labels)
        var labels = service.labels
        labels["com.apple.compose.project"] = project.name
        labels["com.apple.compose.service"] = serviceName
        labels["com.apple.compose.container"] = config.id

        // Attach networks for this service and opt into runtime-managed container DNS.
        let networkIds = try resolvedAttachmentNetworkIds(project: project, service: service)
        let networking = try makeContainerNetworkingConfiguration(
            containerId: config.id,
            networkIds: networkIds
        )
        config.networks = networking.attachments
        config.dns = networking.dns
        config.hosts = try await resolveComposeHosts(
            project: project,
            serviceName: serviceName,
            service: service,
            networkIds: networkIds,
            extraHosts: service.extraHosts,
            primaryNetworkId: networking.attachments.first?.network
        )
        if !config.hosts.isEmpty {
            log.debug(
                "Resolved compose extra_hosts",
                metadata: [
                    "service": "\(serviceName)",
                    "hosts": "\(config.hosts)",
                ]
            )
        }

        // Add port mappings
        config.publishedPorts = try service.ports.map { port in
            try Parser.publishPort(publishSpec(from: port))
        }

        // Add volume mounts (ensure named/anonymous volumes exist and use their host paths)
        config.mounts = try await resolveComposeMounts(
            project: project,
            serviceName: serviceName,
            imageName: imageName,
            mounts: service.volumes
        )

        // Resolve service resources through the shared container defaults path.
        config.resources = try resolvedResources(for: service)

        labels["com.apple.container.compose.config-hash"] = configurationReuseHash(
            project: project,
            serviceName: serviceName,
            service: service,
            configuration: config
        )
        config.labels = labels

        return config
    }

    private func expectedConfigurationHash(
        project: Project,
        serviceName: String,
        service: Service,
        imageName: String,
        removeOnExit: Bool
    ) async throws -> String {
        let configuration = try await createContainerConfiguration(
            project: project,
            serviceName: serviceName,
            service: service,
            imageName: imageName,
            removeOnExit: removeOnExit
        )
        return configurationReuseHash(
            project: project,
            serviceName: serviceName,
            service: service,
            configuration: configuration
        )
    }

    func resolvedResources(for service: Service) throws -> ContainerConfiguration.Resources {
        let cpus: Int64?
        if let cpuString = service.cpus {
            cpus = Int64(try resolvedCPUCount(cpuString))
        } else {
            cpus = nil
        }
        let memory: String?
        if let memStr = service.memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memStr.isEmpty {
            memory = memStr.lowercased() == "max" ? nil : memStr
        } else {
            memory = nil
        }

        return try Parser.resources(cpus: cpus, memory: memory)
    }

    nonisolated internal func resolvedCPUCount(_ cpus: String) throws -> Int {
        let trimmed = cpus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else {
            throw ContainerizationError(.invalidArgument, message: "Invalid cpus value '\(cpus)'")
        }

        var value = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)

        guard decimal == rounded else {
            throw ContainerizationError(.invalidArgument, message: "Fractional cpus value '\(cpus)' is not supported")
        }

        let number = NSDecimalNumber(decimal: rounded)
        let intValue = number.intValue
        guard intValue > 0, number == NSDecimalNumber(value: intValue) else {
            throw ContainerizationError(.invalidArgument, message: "Invalid cpus value '\(cpus)'")
        }

        return intValue
    }

    private func publishSpec(from port: PortMapping) -> String {
        let protoSuffix = port.portProtocol == "tcp" ? "" : "/\(port.portProtocol)"
        if let hostIP = port.hostIP, !hostIP.isEmpty {
            if hostIP.contains(":") {
                return "[\(hostIP)]:\(port.hostPort):\(port.containerPort)\(protoSuffix)"
            }
            return "\(hostIP):\(port.hostPort):\(port.containerPort)\(protoSuffix)"
        }
        return "\(port.hostPort):\(port.containerPort)\(protoSuffix)"
    }

    nonisolated internal func configurationReuseHash(
        project: Project,
        serviceName: String,
        service: Service,
        configuration: ContainerConfiguration
    ) -> String {
        computeConfigHash(
            project: project,
            serviceName: serviceName,
            service: service,
            image: configuration.image,
            process: configuration.initProcess,
            resources: configuration.resources,
            ports: configuration.publishedPorts,
            mounts: configuration.mounts,
            networks: configuration.networks,
            dns: configuration.dns,
            hosts: configuration.hosts
        )
    }

    nonisolated private func computeConfigHash(
        project: Project,
        serviceName: String,
        service: Service,
        image: ImageDescription,
        process: ProcessConfiguration,
        resources: ContainerConfiguration.Resources,
        ports: [PublishPort],
        mounts: [Filesystem],
        networks: [AttachmentConfiguration],
        dns: ContainerConfiguration.DNSConfiguration?,
        hosts: [ContainerConfiguration.HostEntry]
    ) -> String {
        let sig = ConfigSignature(
            image: ImageSig(
                reference: image.reference,
                digest: image.descriptor.digest,
                mediaType: image.descriptor.mediaType,
                size: image.descriptor.size
            ),
            executable: process.executable,
            arguments: process.arguments,
            workdir: process.workingDirectory,
            environment: process.environment,
            cpus: resources.cpus,
            memoryInBytes: resources.memoryInBytes,
            ports: ports.map { PortSig(host: "\($0.hostAddress)", hostPort: Int($0.hostPort), containerPort: Int($0.containerPort), proto: $0.proto == .tcp ? "tcp" : "udp") },
            // For mount hashing, use stable identifiers: for virtiofs binds use host path; for named/anonymous volumes, use logical name
            mounts: mounts.map { m in
                MountSig(source: m.isVolume ? (m.volumeName ?? m.source) : m.source, destination: m.destination, options: m.options)
            },
            networks: networks.map {
                NetworkSig(
                    network: $0.network,
                    hostname: $0.options.hostname,
                    mtu: $0.options.mtu
                )
            },
            dns: dns.map {
                DNSSig(
                    nameservers: $0.nameservers,
                    domain: $0.domain,
                    searchDomains: $0.searchDomains,
                    options: $0.options
                )
            },
            hosts: hosts.map {
                HostSig(ipAddress: $0.ipAddress, hostnames: $0.hostnames)
            },
            labels: service.labels,
            health: service.healthCheck.map { HealthSig(test: $0.test, interval: $0.interval, timeout: $0.timeout, retries: $0.retries, startPeriod: $0.startPeriod) }
        )
        return sig.digest()
    }

    // MARK: - Volume helpers

    /// Resolve compose VolumeMounts to runtime Filesystem entries, ensuring named/anonymous volumes exist.
    internal func resolveComposeMounts(
        project: Project,
        serviceName: String,
        imageName: String,
        mounts: [VolumeMount]
    ) async throws -> [Filesystem] {
        var result: [Filesystem] = []
        for v in mounts {
            switch v.type {
            case .bind:
                try ensureBindSourceExistsIfNeeded(v)
                result.append(Filesystem.virtiofs(source: v.source, destination: v.target, options: v.readOnly ? ["ro"] : []))
            case .tmpfs:
                result.append(Filesystem.tmpfs(destination: v.target, options: v.readOnly ? ["ro"] : []))
            case .volume:
                let name = try resolveVolumeName(project: project, serviceName: serviceName, mount: v)
                let volumeDefinition = project.volumes[v.source]
                let ensured = try await ensureVolume(
                    name: name,
                    isExternal: volumeDefinition?.external ?? false,
                    project: project,
                    serviceName: serviceName,
                    target: v.target
                )
                if ensured.created {
                    try await volumePopulator.populateIfNeeded(
                        volume: ensured.volume,
                        mount: v,
                        imageName: imageName,
                        project: project,
                        serviceName: serviceName,
                        log: log
                    )
                }
                let vol = ensured.volume
                result.append(Filesystem.volume(name: vol.name, format: vol.format, source: vol.source, destination: v.target, options: v.readOnly ? ["ro"] : [], cache: .auto, sync: .full))
            }
        }
        return result
    }

    private func ensureBindSourceExistsIfNeeded(_ mount: VolumeMount) throws {
        guard mount.type == .bind, mount.createHostPath, !mount.source.isEmpty else {
            return
        }
        guard !FileManager.default.fileExists(atPath: mount.source) else {
            return
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: mount.source),
            withIntermediateDirectories: true
        )
    }

    /// Determine volume name; generate deterministic anonymous name for bare container-path mounts.
    internal func resolveVolumeName(project: Project, serviceName: String, mount: VolumeMount) throws -> String {
        // Anonymous volume if source is empty
        if mount.source.isEmpty {
            return anonymousVolumeName(projectName: project.name, serviceName: serviceName, target: mount.target)
        }
        return resolvedProjectVolumeName(project: project, logicalName: mount.source)
    }

    nonisolated internal func resolvedProjectVolumeName(project: Project, logicalName: String) -> String {
        guard let volume = project.volumes[logicalName] else {
            return "\(project.name)_\(logicalName)"
        }

        if let explicitName = volume.externalName, !explicitName.isEmpty {
            return explicitName
        }

        if volume.external {
            return logicalName
        }

        return "\(project.name)_\(logicalName)"
    }

    /// Generate a deterministic anonymous volume name allowed by volume naming rules.
    internal func anonymousVolumeName(projectName: String, serviceName: String, target: String) -> String {
        // Hash the target path to keep names short and deterministic
        let digest = SHA256.hash(data: Data(target.utf8))
        let hash = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(12)
        // Keep characters to [A-Za-z0-9_.-]
        let proj = projectName.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        let svc = serviceName.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
        return "\(proj)_\(svc)_anon_\(hash)"
    }

    /// Ensure a named volume exists; create if missing (unless external). Return inspected volume with host path/format.
    internal func ensureVolume(
        name: String,
        isExternal: Bool,
        project: Project,
        serviceName: String,
        target: String
    ) async throws -> (volume: ContainerResource.Volume, created: Bool) {
        do {
            return (try await volumeClient.inspect(name: name), false)
        } catch {
            if isExternal {
                throw ContainerizationError(.notFound, message: "external volume '\(name)' not found")
            }
            // Create the volume and label it for cleanup and traceability
            let labels: [String: String] = [
                "com.apple.compose.project": project.name,
                "com.apple.compose.service": serviceName,
                "com.apple.compose.target": target,
                "com.apple.compose.anonymous": String(name.contains("_anon_"))
            ]
            _ = try await volumeClient.create(name: name, driver: "local", driverOpts: [:], labels: labels)
            return (try await volumeClient.inspect(name: name), true)
        }
    }

    private struct ConfigSignature: Codable {
        let image: ImageSig
        let executable: String
        let arguments: [String]
        let workdir: String
        let environment: [String]
        let cpus: Int
        let memoryInBytes: UInt64
        let ports: [PortSig]
        let mounts: [MountSig]
        let networks: [NetworkSig]
        let dns: DNSSig?
        let hosts: [HostSig]
        let labels: [String: String]
        let health: HealthSig?

        func canonicalJSON() -> String {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            // normalize arrays by sorting where order is insignificant
            let sortedEnv = environment.sorted()
            let sortedArgs = arguments
            let sortedPorts = ports.sorted { $0.key < $1.key }
            let sortedMounts = mounts.sorted { $0.key < $1.key }
            let sortedNetworks = networks.sorted { $0.key < $1.key }
            let sortedHosts = hosts.sorted { $0.key < $1.key }
            let sortedLabels: [LabelSig] = labels
                .sorted { $0.key < $1.key }
                .map { LabelSig(key: $0.key, value: $0.value) }
            let payload = Canonical(
                image: image,
                executable: executable,
                arguments: sortedArgs,
                workdir: workdir,
                environment: sortedEnv,
                cpus: cpus,
                memoryInBytes: memoryInBytes,
                ports: sortedPorts,
                mounts: sortedMounts,
                networks: sortedNetworks,
                dns: dns,
                hosts: sortedHosts,
                labels: sortedLabels,
                health: health
            )
            let data = try! enc.encode(payload)
            return String(data: data, encoding: .utf8)!
        }

        func digest() -> String {
            let json = canonicalJSON()
            let d = SHA256.hash(data: json.data(using: .utf8)!)
            return d.compactMap { String(format: "%02x", $0) }.joined()
        }

        struct Canonical: Codable {
            let image: ImageSig
            let executable: String
            let arguments: [String]
            let workdir: String
            let environment: [String]
            let cpus: Int
            let memoryInBytes: UInt64
            let ports: [PortSig]
            let mounts: [MountSig]
            let networks: [NetworkSig]
            let dns: DNSSig?
            let hosts: [HostSig]
            let labels: [LabelSig]
            let health: HealthSig?
        }
    }

    private struct ImageSig: Codable {
        let reference: String
        let digest: String
        let mediaType: String
        let size: Int64
    }

    private struct LabelSig: Codable {
        let key: String
        let value: String
    }

    private struct PortSig: Codable {
        let host: String
        let hostPort: Int
        let containerPort: Int
        let proto: String
        var key: String { "\(host):\(hostPort)->\(containerPort)/\(proto)" }
    }

    private struct MountSig: Codable {
        let source: String
        let destination: String
        let options: [String]
        var key: String { "\(destination)=\(source):\(options.sorted().joined(separator: ","))" }
    }

    private struct NetworkSig: Codable {
        let network: String
        let hostname: String
        let mtu: UInt32?
        var key: String { "\(network)=\(hostname):\(mtu.map(String.init) ?? "")" }
    }

    private struct DNSSig: Codable {
        let nameservers: [String]
        let domain: String?
        let searchDomains: [String]
        let options: [String]
    }

    private struct HostSig: Codable {
        let ipAddress: String
        let hostnames: [String]
        var key: String { "\(ipAddress)=\(hostnames.sorted().joined(separator: ","))" }
    }

    private struct HealthSig: Codable {
        let test: [String]
        let interval: TimeInterval?
        let timeout: TimeInterval?
        let retries: Int?
        let startPeriod: TimeInterval?
    }

    /// Build images for services that need building
    internal func buildImagesIfNeeded(
        project: Project,
        services: [String: Service],
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Find services that need building
        let servicesToBuild = services.filter { $0.value.hasBuild }

        if servicesToBuild.isEmpty {
            log.debug("No services need building")
            return
        }

        log.info("Building images for \(servicesToBuild.count) service(s)")

        // Separate cached and non-cached builds
        var cachedBuilds = [(String, String)]() // (serviceName, cachedImageName)
        var buildsToExecute = [(String, Service)]() // (serviceName, service)

        for (serviceName, service) in servicesToBuild {
            guard let buildConfig = service.build else { continue }

            // Generate cache key based on build context
            let cacheKey = buildCacheKey(serviceName: serviceName, buildConfig: buildConfig, projectName: project.name)

            // Check if we have a cached build
            if let cachedImage = buildCache[cacheKey] {
                log.info("Using cached image '\(cachedImage)' for service '\(serviceName)'")
                cachedBuilds.append((serviceName, cachedImage))
            } else {
                buildsToExecute.append((serviceName, service))
            }
        }

        // Build non-cached images in parallel where possible
        if !buildsToExecute.isEmpty {
            try await buildImagesInParallel(
                builds: buildsToExecute,
                project: project,
                progressHandler: progressHandler
            )
        }

        // Log summary
        if !cachedBuilds.isEmpty {
            log.info("Used \(cachedBuilds.count) cached image(s)")
        }
        if !buildsToExecute.isEmpty {
            log.info("Built \(buildsToExecute.count) new image(s)")
        }
    }

    /// Build images in parallel with resource management
    private func buildImagesInParallel(
        builds: [(String, Service)],
        project: Project,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        // Limit concurrent builds to avoid overwhelming the system
        let maxConcurrentBuilds = min(builds.count, 3)

        try await withThrowingTaskGroup(of: (String, String).self) { group in
            var buildsIterator = builds.makeIterator()
            var activeBuilds = 0

            // Start initial batch of builds
            while activeBuilds < maxConcurrentBuilds, let nextBuild = buildsIterator.next() {
                activeBuilds += 1
                group.addTask {
                    let targetTag = nextBuild.1.effectiveImageName(projectName: project.name)
                    let imageName = try await self.buildSingleImage(
                        serviceName: nextBuild.0,
                        service: nextBuild.1,
                        project: project,
                        targetTag: targetTag,
                        progressHandler: progressHandler
                    )
                    return (nextBuild.0, imageName)
                }
            }

            // Process completed builds and start new ones
            for try await (serviceName, imageName) in group {
                activeBuilds -= 1

                // Cache the built image
                if let buildConfig = builds.first(where: { $0.0 == serviceName })?.1.build {
                    let cacheKey = buildCacheKey(serviceName: serviceName, buildConfig: buildConfig, projectName: project.name)
                    buildCache[cacheKey] = imageName
                }

                // Start next build if available
                if let nextBuild = buildsIterator.next() {
                    activeBuilds += 1
                    group.addTask {
                        let targetTag = nextBuild.1.effectiveImageName(projectName: project.name)
                        let imageName = try await self.buildSingleImage(
                            serviceName: nextBuild.0,
                            service: nextBuild.1,
                            project: project,
                            targetTag: targetTag,
                            progressHandler: progressHandler
                        )
                        return (nextBuild.0, imageName)
                    }
                }
            }
        }
    }

    /// Build a single image
    private func buildSingleImage(
        serviceName: String,
        service: Service,
        project: Project,
        targetTag: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String {
        guard let buildConfig = service.build else {
            throw ContainerizationError(
                .internalError,
                message: "Service '\(serviceName)' has no build configuration"
            )
        }

        log.info("Building image for service '\(serviceName)'")

        do {
            let builtImageName = try await buildService.buildImage(
                serviceName: serviceName,
                buildConfig: buildConfig,
                projectName: project.name,
                targetTag: targetTag,
                progressHandler: progressHandler
            )

            log.info("Built image '\(builtImageName)' for service '\(serviceName)'")
            return builtImageName

        } catch let error as ContainerizationError {
            log.error("Failed to build image for service '\(serviceName)': \(error)")
            throw error
        } catch {
            log.error("Failed to build image for service '\(serviceName)': \(error)")
            throw ContainerizationError(
                .internalError,
                message: "Failed to build image for service '\(serviceName)': \(error.localizedDescription)"
            )
        }
    }

    /// Generate a cache key for a build configuration
    private func buildCacheKey(serviceName: String, buildConfig: BuildConfig, projectName: String) -> String {
        let context = buildConfig.context ?? "."
        let dockerfile = buildConfig.dockerfile ?? "Dockerfile"
        let args = buildConfig.args ?? [:]
        let argsString = args.keys.sorted().map { key in "\(key)=\(args[key] ?? "")" }.joined(separator: ";")
        let key = "\(projectName)|\(serviceName)|\(context)|\(dockerfile)|\(argsString)"
        let digest = SHA256.hash(data: key.data(using: .utf8)!)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Compose Networks

    /// Ensure non-external compose networks exist (macOS 26+). External networks must already exist.
    private func ensureComposeNetworks(project: Project) async throws {
        // If no networks defined at project level, nothing to do
        guard !project.networks.isEmpty else { return }

        // Multi-network support requires macOS 26+
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }

        for (_, net) in project.networks {
            // Only support bridge driver
            if net.driver.lowercased() != "bridge" {
                throw ContainerizationError(.invalidArgument, message: "unsupported network driver '\(net.driver)' (only 'bridge' is supported)")
            }

            let id = networkId(for: project, networkName: net.name, external: net.external, externalName: net.externalName)
            if net.external {
                // External network must already exist
                do { _ = try await ClientNetwork.get(id: id) } catch {
                    throw ContainerizationError(.notFound, message: "external network '\(id)' not found")
                }
            } else {
                // Ensure/create project-scoped bridge network
                do {
                    _ = try await ClientNetwork.get(id: id)
                } catch {
                    _ = try await ClientNetwork.create(
                        configuration: try NetworkConfiguration(
                            id: id,
                            mode: .nat,
                            labels: [:],
                            pluginInfo: NetworkPluginInfo(plugin: "container-network-vmnet")
                        )
                    )
                }
            }
        }
    }

    /// Map declared service networks to Apple Container network IDs, honoring external vs project-scoped.
    nonisolated internal func mapServiceNetworkIds(project: Project, service: Service) throws -> [String] {
        if let networkMode = service.networkMode?.lowercased() {
            switch networkMode {
            case "bridge":
                return []
            default:
                throw ContainerizationError(
                    .invalidArgument,
                    message: "unsupported network_mode '\(networkMode)'; only 'bridge' is currently supported"
                )
            }
        }
        guard !service.networks.isEmpty else { return [] }
        // macOS gate aligns with Utility.getAttachmentConfigurations behavior
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }
        return service.networks.map { name in
            let def = project.networks[name]
            return networkId(for: project,
                              networkName: def?.name ?? name,
                              external: def?.external ?? false,
                              externalName: def?.externalName)
        }
    }

    nonisolated internal func resolvedAttachmentNetworkIds(project: Project, service: Service) throws -> [String] {
        let explicitNetworkIds = try mapServiceNetworkIds(project: project, service: service)
        guard shouldAttachRuntimeDefaultNetwork(service: service, explicitNetworkIds: explicitNetworkIds) else {
            return explicitNetworkIds
        }
        return [ClientNetwork.defaultNetworkName] + explicitNetworkIds.filter { $0 != ClientNetwork.defaultNetworkName }
    }

    nonisolated internal func shouldAttachRuntimeDefaultNetwork(service: Service, explicitNetworkIds: [String]? = nil) -> Bool {
        guard service.networkMode == nil else { return false }
        let hasExplicitComposeNetworks = !(explicitNetworkIds ?? service.networks).isEmpty
        guard hasExplicitComposeNetworks else { return false }
        return service.extraHosts.contains { $0.address == "host-gateway" }
    }

    nonisolated internal func composeNetworkNames(for service: Service) -> [String] {
        guard service.networkMode == nil else {
            return []
        }
        return service.networks.isEmpty ? ["default"] : service.networks
    }

    nonisolated internal func composeNetworkIdsByName(
        project: Project,
        service: Service
    ) throws -> [String: String] {
        let composeNetworks = composeNetworkNames(for: service)
        guard !composeNetworks.isEmpty else {
            return [:]
        }
        if service.networks.isEmpty {
            return ["default": ClientNetwork.defaultNetworkName]
        }

        return Dictionary(
            uniqueKeysWithValues: composeNetworks.map { networkName in
                let network = project.networks[networkName]
                let resolvedNetworkName = network?.name ?? networkName
                let networkId = networkId(
                    for: project,
                    networkName: resolvedNetworkName,
                    external: network?.external ?? false,
                    externalName: network?.externalName
                )
                return (networkName, networkId)
            }
        )
    }

    nonisolated private func networkId(for project: Project, networkName: String, external: Bool, externalName: String?) -> String {
        if let externalName, !externalName.isEmpty { return externalName }
        if external { return networkName }
        return "\(project.name)_\(networkName)"
    }

    /// Build network attachments and DNS settings consistent with the base container CLI.
    nonisolated internal func makeContainerNetworkingConfiguration(
        containerId: String,
        networkIds: [String]
    ) throws -> (dns: ContainerConfiguration.DNSConfiguration, attachments: [AttachmentConfiguration]) {
        let dnsDomain = DefaultsStore.getOptional(key: .defaultDNSDomain)
        let dns = ContainerConfiguration.DNSConfiguration(nameservers: [], domain: dnsDomain)
        let primaryHostname = composePrimaryHostname(containerId: containerId, dnsDomain: dnsDomain)

        guard !networkIds.isEmpty else {
            return (
                dns,
                [AttachmentConfiguration(
                    network: ClientNetwork.defaultNetworkName,
                    options: AttachmentOptions(hostname: primaryHostname, mtu: 1280)
                )]
            )
        }
        guard #available(macOS 26, *) else {
            throw ContainerizationError(.invalidArgument, message: "non-default network configuration requires macOS 26 or newer")
        }
        // The first network remains primary by virtue of order.
        let attachments = networkIds.enumerated().map { offset, id in
            let hostname = offset == 0 ? primaryHostname : containerId
            return AttachmentConfiguration(network: id, options: AttachmentOptions(hostname: hostname, mtu: 1280))
        }
        return (dns, attachments)
    }

    nonisolated internal func composePrimaryHostname(containerId: String, dnsDomain: String?) -> String {
        if !containerId.contains(".") {
            if let dnsDomain, !dnsDomain.isEmpty {
                return "\(containerId).\(dnsDomain)."
            }
            return containerId
        }
        return "\(containerId)."
    }

    internal func resolveComposeHosts(
        project: Project,
        serviceName: String,
        service: Service,
        networkIds: [String],
        extraHosts: [ExtraHost],
        primaryNetworkId: String?
    ) async throws -> [ContainerConfiguration.HostEntry] {
        let peerHosts = try await resolveComposePeerHosts(
            project: project,
            serviceName: serviceName,
            service: service
        )

        guard !extraHosts.isEmpty else { return peerHosts }

        let gatewayAddress = try await resolveHostGatewayAddress(primaryNetworkId: primaryNetworkId)
        let resolvedExtraHosts = extraHosts.map { host in
            let address = host.address == "host-gateway" ? gatewayAddress : host.address
            return ContainerConfiguration.HostEntry(ipAddress: address, hostnames: [host.hostname])
        }
        return mergeHostEntries(peerHosts + resolvedExtraHosts)
    }

    internal func resolveComposePeerHosts(
        project: Project,
        serviceName: String,
        service: Service
    ) async throws -> [ContainerConfiguration.HostEntry] {
        guard !composeNetworkNames(for: service).isEmpty else { return [] }

        let plannedPeerHosts = try await resolvePlannedComposePeerHosts(
            project: project,
            serviceName: serviceName,
            service: service
        )

        let allContainers = try await containerClient.list()
        let startupServiceNames = Set(activeStartupServices.keys)
        let runtimePeerHosts = try composePeerHosts(
            project: project,
            serviceName: serviceName,
            service: service,
            containers: allContainers.filter { snapshot in
                guard let peerServiceName = snapshot.configuration.labels["com.apple.compose.service"] else {
                    return true
                }
                return !startupServiceNames.contains(peerServiceName)
            }
        )

        return mergeHostEntries(plannedPeerHosts + runtimePeerHosts)
    }

    private func resolvePlannedComposePeerHosts(
        project: Project,
        serviceName: String,
        service: Service
    ) async throws -> [ContainerConfiguration.HostEntry] {
        let currentComposeNetworks = composeNetworkNames(for: service)
        guard !currentComposeNetworks.isEmpty else { return [] }
        guard !activeStartupServices.isEmpty else { return [] }

        var plannedAttachments: [ComposePeerAttachment] = []

        for (peerServiceName, peerService) in activeStartupServices {
            guard peerServiceName != serviceName else { continue }

            let explicitAttachments = try plannedComposeNetworkAttachments(
                project: project,
                serviceName: peerServiceName,
                service: peerService
            )
            let sharedNetworks = currentComposeNetworks.filter { explicitAttachments[$0] != nil }

            for networkName in sharedNetworks {
                guard let attachment = explicitAttachments[networkName] else { continue }
                let reservedAttachment = try await lookupOrReserveComposeAttachment(
                    serviceName: peerServiceName,
                    networkId: attachment.network,
                    hostname: attachment.options.hostname
                )
                plannedAttachments.append(
                    ComposePeerAttachment(
                        serviceName: peerServiceName,
                        networkName: networkName,
                        ipAddress: reservedAttachment.ipv4Address.address.description,
                        aliases: peerService.networkAliases[networkName] ?? []
                    )
                )
            }
        }

        return composePeerHosts(plannedAttachments: plannedAttachments)
    }

    private func lookupOrReserveComposeAttachment(
        serviceName: String,
        networkId: String,
        hostname: String
    ) async throws -> Attachment {
        let networkState = try await ClientNetwork.get(id: networkId)
        guard let plugin = networkState.pluginInfo?.plugin else {
            throw ContainerizationError(.internalError, message: "network \(networkId) is missing plugin information")
        }

        let client = NetworkClient(id: networkId, plugin: plugin)
        if let existing = try await client.lookup(hostname: hostname) {
            return existing
        }

        let (attachment, _) = try await client.allocate(hostname: hostname)
        trackComposeHostReservation(
            serviceName: serviceName,
            networkId: networkId,
            hostname: hostname,
            plugin: plugin
        )
        return attachment
    }

    nonisolated internal func plannedComposeNetworkAttachments(
        project: Project,
        serviceName: String,
        service: Service
    ) throws -> [String: AttachmentConfiguration] {
        let composeNetworks = composeNetworkNames(for: service)
        guard !composeNetworks.isEmpty else {
            return [:]
        }

        let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
        if service.networks.isEmpty {
            let networking = try makeContainerNetworkingConfiguration(containerId: containerId, networkIds: [])
            if let attachment = networking.attachments.first {
                return ["default": attachment]
            }
            return [:]
        }

        let explicitNetworkIds = try mapServiceNetworkIds(project: project, service: service)
        let networkIds = try resolvedAttachmentNetworkIds(project: project, service: service)
        let networking = try makeContainerNetworkingConfiguration(
            containerId: containerId,
            networkIds: networkIds
        )
        let attachmentByNetworkId = Dictionary(
            uniqueKeysWithValues: networking.attachments.map { ($0.network, $0) }
        )

        var attachmentsByName: [String: AttachmentConfiguration] = [:]
        for (networkName, networkId) in zip(composeNetworks, explicitNetworkIds) {
            if let attachment = attachmentByNetworkId[networkId] {
                attachmentsByName[networkName] = attachment
            }
        }
        return attachmentsByName
    }

    nonisolated internal func composePeerHosts(
        plannedAttachments: [ComposePeerAttachment]
    ) -> [ContainerConfiguration.HostEntry] {
        var hostnamesByAddress: [String: Set<String>] = [:]

        for plannedAttachment in plannedAttachments {
            var hostnames = hostnamesByAddress[plannedAttachment.ipAddress] ?? []
            hostnames.insert(plannedAttachment.serviceName)
            hostnames.formUnion(plannedAttachment.aliases)
            hostnamesByAddress[plannedAttachment.ipAddress] = hostnames
        }

        return hostnamesByAddress.map { address, hostnames in
            ContainerConfiguration.HostEntry(
                ipAddress: address,
                hostnames: Array(hostnames).sorted()
            )
        }
        .sorted { $0.ipAddress < $1.ipAddress }
    }

    nonisolated internal func composePeerHosts(
        project: Project,
        serviceName: String,
        service: Service,
        containers: [ContainerSnapshot]
    ) throws -> [ContainerConfiguration.HostEntry] {
        let currentNetworkIds = try Dictionary(
            uniqueKeysWithValues: composeNetworkIdsByName(project: project, service: service).map { networkName, networkId in
                (networkId, networkName)
            }
        )
        guard !currentNetworkIds.isEmpty else { return [] }

        var hostnamesByAddress: [String: Set<String>] = [:]

        for peerContainer in containers {
            guard peerContainer.status == .running else { continue }
            guard peerContainer.configuration.labels["com.apple.compose.project"] == project.name else { continue }
            guard let peerServiceName = peerContainer.configuration.labels["com.apple.compose.service"] else { continue }
            guard peerServiceName != serviceName else { continue }

            for attachment in peerContainer.networks {
                guard let networkName = currentNetworkIds[attachment.network] else { continue }

                let address = attachment.ipv4Address.address.description
                var hostnames = hostnamesByAddress[address] ?? []
                hostnames.insert(peerServiceName)
                if let peerService = project.services[peerServiceName] {
                    hostnames.formUnion(peerService.networkAliases[networkName] ?? [])
                }
                hostnamesByAddress[address] = hostnames
            }
        }

        return hostnamesByAddress.map { address, hostnames in
            ContainerConfiguration.HostEntry(
                ipAddress: address,
                hostnames: Array(hostnames).sorted()
            )
        }
        .sorted { $0.ipAddress < $1.ipAddress }
    }

    nonisolated private func mergeHostEntries(_ entries: [ContainerConfiguration.HostEntry]) -> [ContainerConfiguration.HostEntry] {
        var hostnamesByAddress: [String: Set<String>] = [:]
        for entry in entries {
            hostnamesByAddress[entry.ipAddress, default: []].formUnion(entry.hostnames)
        }
        return hostnamesByAddress.map { ipAddress, hostnames in
            ContainerConfiguration.HostEntry(ipAddress: ipAddress, hostnames: Array(hostnames).sorted())
        }
        .sorted { $0.ipAddress < $1.ipAddress }
    }

    internal func resolveHostGatewayAddress(primaryNetworkId: String?) async throws -> String {
        let networkId = primaryNetworkId ?? ClientNetwork.defaultNetworkName
        let network = try await ClientNetwork.get(id: networkId)
        switch network {
        case .running(_, let status):
            return status.ipv4Gateway.description
        case .created:
            throw ContainerizationError(.internalError, message: "network \(networkId) does not have an allocated gateway yet")
        }
    }

    /// Stop and remove services in a project
    public func down(
        project: Project,
        removeVolumes: Bool = false,
        removeOrphans: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> DownResult {
        log.info("Stopping project '\(project.name)'")

        // Determine containers to remove
        let expectedIds: Set<String> = Set(project.services.map { name, svc in
            svc.containerName ?? "\(project.name)_\(name)"
        })

        var removedContainers: [String] = []
        do {
            let all = try await containerClient.list()
            let targets: [ContainerSnapshot] = all.filter { container in
                matchesDownTarget(
                    projectName: project.name,
                    expectedIds: expectedIds,
                    container: container,
                    removeOrphans: removeOrphans
                )
            }

            for c in targets {
                // Best-effort stop then delete
                do { try await containerClient.stop(id: c.id) } catch { log.warning("failed to stop \(c.id): \(error)") }
                do { try await containerClient.delete(id: c.id) } catch { log.warning("failed to delete \(c.id): \(error)") }
                removedContainers.append(c.id)
            }
        } catch {
            log.warning("Failed to enumerate project containers: \(error)")
        }

        // Optionally remove volumes defined in the project (non-external)
        var removedVolumes: [String] = []
        if removeVolumes {
            for volumeName in managedVolumeNamesForRemoval(project: project) {
                do { try await volumeClient.delete(name: volumeName); removedVolumes.append(volumeName) }
                catch { log.warning("failed to delete volume \(volumeName): \(error)") }
            }

            // Also remove anonymous per-service volumes created for bare "/path" mounts
            do {
                let all = try await volumeClient.list()
                for v in all {
                    if v.labels["com.apple.compose.project"] == project.name,
                       v.labels["com.apple.compose.anonymous"] == "true" {
                        do { try await volumeClient.delete(name: v.name); removedVolumes.append(v.name) }
                        catch { log.warning("failed to delete anonymous volume \(v.name): \(error)") }
                    }
                }
            } catch {
                log.warning("failed to enumerate volumes for anonymous cleanup: \(error)")
            }
        }

        // Optionally remove compose-created networks (non-external)
        do {
            for (_, net) in project.networks {
                guard !net.external else { continue }
                let id = networkId(for: project, networkName: net.name, external: false, externalName: net.externalName)
                // Best effort: delete if present
                do { try await ClientNetwork.delete(id: id) } catch { log.warning("failed to delete network \(id): \(error)") }
            }
        }

        // Clear project state
        projectState[project.name] = nil

        log.info("Project '\(project.name)' stopped and removed")
        return DownResult(removedContainers: removedContainers, removedVolumes: removedVolumes)
    }

    /// Get service statuses
    public func ps(project: Project, all: Bool = false) async throws -> [ServiceStatus] {
        let idToService: [String: String] = Dictionary(uniqueKeysWithValues: project.services.map { (name, svc) in
            let id = svc.containerName ?? "\(project.name)_\(name)"
            return (id, name)
        })
        let containers = try await containerClient.list(filters: psContainerListFilters(all: all))
        let filtered = containers.filter { c in
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name { return true }
            // Fallback to prefix if labels are missing
            return c.id.hasPrefix("\(project.name)_")
        }
        var statuses: [ServiceStatus] = []
        for c in filtered {
            let serviceName = c.configuration.labels["com.apple.compose.service"] ?? idToService[c.id] ?? c.id
            let portsStr: String = c.configuration.publishedPorts.map { p in
                let host = p.hostAddress
                return "\(host):\(p.hostPort)->\(p.containerPort)/\(p.proto == .tcp ? "tcp" : "udp")"
            }.joined(separator: ", ")
            let statusStr = c.status.rawValue
            let imageRef = c.configuration.image.reference
            let shortId = String(c.id.prefix(12))
            statuses.append(ServiceStatus(name: serviceName,
                                          containerID: shortId,
                                          containerName: c.id,
                                          status: statusStr,
                                          ports: portsStr,
                                          image: imageRef))
        }
        return statuses
    }

    nonisolated internal func psContainerListFilters(all: Bool) -> ContainerListFilters {
        all ? .all : ContainerListFilters(status: .running)
    }

    /// Get logs from services
    public func logs(
        project: Project,
        services: [String] = [],
        follow: Bool = false,
        tail: Int? = nil,
        timestamps: Bool = false,
        includeBoot: Bool = false
    ) async throws -> AsyncThrowingStream<LogEntry, Error> {
        // Resolve target services
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)

        // Find matching containers (prefer labels)
        let all = try await containerClient.list()
        var targets: [(service: String, container: ContainerSnapshot)] = []
        for c in all {
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                let svc = c.configuration.labels["com.apple.compose.service"] ?? c.id
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
                continue
            }
            // Fallback by id
            let prefix = "\(project.name)_"
            if c.id.hasPrefix(prefix) {
                let svc = String(c.id.dropFirst(prefix.count))
                if services.isEmpty || selected.contains(svc) {
                    targets.append((svc, c))
                }
            }
        }

        return AsyncThrowingStream { continuation in
            // If no targets, finish immediately
            if targets.isEmpty { continuation.finish(); return }

            final class Emitter: @unchecked Sendable {
                let cont: AsyncThrowingStream<LogEntry, Error>.Continuation
                // Strongly retain file handles so readabilityHandler keeps firing.
                private var retained: [FileHandle] = []
                init(_ c: AsyncThrowingStream<LogEntry, Error>.Continuation) { self.cont = c }
                func emit(_ entries: [LogEntry]) {
                    for entry in entries {
                        cont.yield(entry)
                    }
                }
                func retain(_ fh: FileHandle) { retained.append(fh) }
                func finish() { cont.finish() }
                func fail(_ error: Error) { cont.yield(with: .failure(error)) }
            }
            let emitter = Emitter(continuation)
            actor FollowState {
                private var data: Data
                private var finished: Bool

                init(_ data: Data = Data(), finished: Bool = false) {
                    self.data = data
                    self.finished = finished
                }

                func buffer() -> Data {
                    data
                }

                func setBuffer(_ newValue: Data) {
                    data = newValue
                }

                func finishIfNeeded() -> Data? {
                    guard !finished else { return nil }
                    finished = true
                    return data
                }
            }
            actor Counter {
                var value: Int
                init(_ v: Int) { value = v }
                func dec(by amount: Int = 1) -> Int {
                    value -= amount
                    return value
                }
            }
            let streamsPerContainer = includeBoot ? 2 : 1
            let counter = Counter(targets.count * streamsPerContainer)

            // For each container, open log file handles in async tasks
            for (svc, container) in targets {
                Task.detached {
                    do {
                        let fds = try await self.containerClient.logs(id: container.id)
                        let handles: [(FileHandle, LogEntry.LogStream)] = includeBoot
                            ? [(fds[0], .stdout), (fds[1], .stderr)]
                            : [(fds[0], .stdout)]

                        for (fh, stream) in handles {
                            let initialData = try self.readLogData(fileHandle: fh, tail: tail)
                            let initial = self.decodeLogChunk(
                                serviceName: svc,
                                containerName: container.id,
                                stream: stream,
                                buffer: Data(),
                                incoming: initialData,
                                timestamps: timestamps,
                                flush: !follow
                            )
                            emitter.emit(initial.entries)

                            if follow {
                                if self.followEOFAction(status: container.status) == .finish {
                                    let final = self.decodeLogChunk(
                                        serviceName: svc,
                                        containerName: container.id,
                                        stream: stream,
                                        buffer: initial.remainder,
                                        incoming: Data(),
                                        timestamps: timestamps,
                                        flush: true
                                    )
                                    emitter.emit(final.entries)
                                    let left = await counter.dec()
                                    if left == 0 { emitter.finish() }
                                    continue
                                }

                                _ = try? fh.seekToEnd()
                                let state = FollowState(initial.remainder)
                                fh.readabilityHandler = { handle in
                                    let data = handle.availableData
                                    Task {
                                        if data.isEmpty {
                                            let status = (try? await self.containerClient.get(id: container.id).status) ?? .stopped
                                            switch self.followEOFAction(status: status) {
                                            case .finish:
                                                fh.readabilityHandler = nil
                                                let trailingData = (try? fh.readToEnd()) ?? Data()
                                                if let remainder = await state.finishIfNeeded() {
                                                    let final = self.decodeLogChunk(
                                                        serviceName: svc,
                                                        containerName: container.id,
                                                        stream: stream,
                                                        buffer: remainder,
                                                        incoming: trailingData,
                                                        timestamps: timestamps,
                                                        flush: true
                                                    )
                                                    emitter.emit(final.entries)
                                                    let left = await counter.dec()
                                                    if left == 0 { emitter.finish() }
                                                }
                                            case .keepFollowing:
                                                _ = try? fh.seekToEnd()
                                            }
                                            return
                                        }

                                        let buffer = await state.buffer()
                                        let parsed = self.decodeLogChunk(
                                            serviceName: svc,
                                            containerName: container.id,
                                            stream: stream,
                                            buffer: buffer,
                                            incoming: data,
                                            timestamps: timestamps,
                                            flush: false
                                        )
                                        await state.setBuffer(parsed.remainder)
                                        emitter.emit(parsed.entries)
                                    }
                                }
                                emitter.retain(fh)

                                Task.detached {
                                    while true {
                                        let status = (try? await self.containerClient.get(id: container.id).status) ?? .stopped
                                        guard self.followEOFAction(status: status) == .keepFollowing else {
                                            fh.readabilityHandler = nil
                                            let trailingData = (try? fh.readToEnd()) ?? Data()
                                            if let remainder = await state.finishIfNeeded() {
                                                let final = self.decodeLogChunk(
                                                    serviceName: svc,
                                                    containerName: container.id,
                                                    stream: stream,
                                                    buffer: remainder,
                                                    incoming: trailingData,
                                                    timestamps: timestamps,
                                                    flush: true
                                                )
                                                emitter.emit(final.entries)
                                                let left = await counter.dec()
                                                if left == 0 { emitter.finish() }
                                            }
                                            return
                                        }

                                        try? await Task.sleep(nanoseconds: 250_000_000)
                                    }
                                }
                            } else {
                                let final = self.decodeLogChunk(
                                    serviceName: svc,
                                    containerName: container.id,
                                    stream: stream,
                                    buffer: initial.remainder,
                                    incoming: Data(),
                                    timestamps: timestamps,
                                    flush: true
                                )
                                emitter.emit(final.entries)
                                let left = await counter.dec()
                                if left == 0 { emitter.finish() }
                            }
                        }
                    } catch {
                        emitter.fail(error)
                        let left = await counter.dec(by: streamsPerContainer)
                        if left == 0 { emitter.finish() }
                    }
                }
            }
        }
    }

    internal enum LogFollowEOFAction: Equatable {
        case finish
        case keepFollowing
    }

    nonisolated internal func followEOFAction(status: RuntimeStatus) -> LogFollowEOFAction {
        status == .running ? .keepFollowing : .finish
    }

    nonisolated internal func readLogData(fileHandle: FileHandle, tail: Int?) throws -> Data {
        let data = try fileHandle.readToEnd() ?? Data()
        return tailedLogData(data, tail: tail)
    }

    nonisolated internal func tailedLogData(_ data: Data, tail: Int?) -> Data {
        guard let tail else { return data }
        guard tail > 0 else { return Data() }
        guard let text = String(data: data, encoding: .utf8) else { return data }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if normalized.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }
        let tailedLines = lines.suffix(tail)
        return Data(tailedLines.joined(separator: "\n").utf8)
    }

    nonisolated internal func decodeLogChunk(
        serviceName: String,
        containerName: String,
        stream: LogEntry.LogStream,
        buffer: Data,
        incoming: Data,
        timestamps: Bool,
        flush: Bool
    ) -> (entries: [LogEntry], remainder: Data) {
        var combined = buffer
        combined.append(incoming)
        guard !combined.isEmpty else {
            return ([], Data())
        }

        let normalized = String(decoding: combined, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasTrailingNewline = normalized.hasSuffix("\n")
        let remainder: Data

        if hasTrailingNewline {
            if !lines.isEmpty {
                lines.removeLast()
            }
            remainder = Data()
        } else if flush {
            remainder = Data()
        } else {
            let tail = lines.popLast() ?? ""
            remainder = Data(tail.utf8)
        }

        let entries = lines.map {
            parsedLogEntry(
                serviceName: serviceName,
                containerName: containerName,
                stream: stream,
                line: $0,
                timestamps: timestamps
            )
        }
        return (entries, remainder)
    }

    nonisolated internal func parsedLogEntry(
        serviceName: String,
        containerName: String,
        stream: LogEntry.LogStream,
        line: String,
        timestamps: Bool
    ) -> LogEntry {
        let parsed: (timestamp: Date?, message: String) = timestamps ? parseTimestampPrefix(line) : (nil, line)
        return LogEntry(
            serviceName: serviceName,
            containerName: containerName,
            message: parsed.message,
            stream: stream,
            timestamp: parsed.timestamp
        )
    }

    nonisolated internal func parseTimestampPrefix(_ line: String) -> (timestamp: Date?, message: String) {
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 2 else {
            return (nil, line)
        }

        let formatters: [ISO8601DateFormatter] = [
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter
            }(),
            {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter
            }(),
        ]

        for formatter in formatters {
            if let timestamp = formatter.date(from: parts[0]) {
                return (timestamp, parts[1])
            }
        }

        return (nil, line)
    }

    /// Start stopped services
    public func start(
        project: Project,
        services: [String] = [],
        disableHealthcheck: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        let targetServices = services.isEmpty ? project.services : project.services.filter { services.contains($0.key) }
        if targetServices.isEmpty { return }
        let scopedServices = DependencyResolver.scopeToSelection(services: targetServices)
        let resolution = try DependencyResolver.resolve(services: scopedServices)

        for serviceName in resolution.startOrder {
            guard let service = targetServices[serviceName] else { continue }
            try await waitForDependencyConditions(
                project: project,
                serviceName: serviceName,
                services: scopedServices,
                disableHealthcheck: disableHealthcheck
            )
            let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
            guard let container = try await findRuntimeContainer(byId: containerId) else {
                throw ContainerizationError(.notFound, message: "Service '\(serviceName)' container not found")
            }
            guard container.status != .running else { continue }

            for mount in container.configuration.mounts where mount.isVirtiofs {
                if !FileManager.default.fileExists(atPath: mount.source) {
                    throw ContainerizationError(.invalidState, message: "path '\(mount.source)' is not a directory")
                }
            }

            let initProcess = try await containerClient.bootstrap(id: container.id, stdio: [nil, nil, nil])
            try await initProcess.start()
        }
    }



    /// Stop running services
    public func stop(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        let targetServices = services.isEmpty ? project.services : project.services.filter { services.contains($0.key) }
        if targetServices.isEmpty { return }
        let resolution = try DependencyResolver.resolveWithinSelection(services: targetServices)

        for serviceName in resolution.stopOrder {
            guard let service = targetServices[serviceName] else { continue }
            let containerId = service.containerName ?? "\(project.name)_\(serviceName)"
            guard let container = try await findRuntimeContainer(byId: containerId) else { continue }
            guard container.status == .running else { continue }
            try await containerClient.stop(
                id: container.id,
                opts: ContainerStopOptions(timeoutInSeconds: Int32(timeout), signal: SIGTERM)
            )
        }
    }

    /// Restart services
    public func restart(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        disableHealthcheck: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        try await stop(project: project, services: services, timeout: timeout, progressHandler: progressHandler)
        try await start(project: project, services: services, disableHealthcheck: disableHealthcheck, progressHandler: progressHandler)
    }

    /// Execute command in a service
    public func exec(
        project: Project,
        serviceName: String,
        command: [String],
        detach: Bool = false,
        interactive: Bool = false,
        tty: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        environment: [String] = [],
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> Int32 {
        let containerId = project.services[serviceName]?.containerName ?? "\(project.name)_\(serviceName)"
        guard let container = try await findRuntimeContainer(byId: containerId) else {
            throw ContainerizationError(.notFound, message: "Service '\(serviceName)' container not found")
        }

        // Build process configuration
        let executable = command.first ?? "/bin/sh"
        let args = Array(command.dropFirst())
        var proc = ProcessConfiguration(
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: workdir ?? "/",
            terminal: tty
        )
        if let user = user { proc.user = .raw(userString: user) }

        let stdio = processStdio(detach: detach, interactive: interactive, tty: tty)

        let pid = "exec-\(UUID().uuidString)"
        let process = try await containerClient.createProcess(
            containerId: container.id,
            processId: pid,
            configuration: proc,
            stdio: stdio
        )
        try await process.start()

        if detach { return 0 }

        installProcessSignalForwarders(process: process)

        return try await process.wait()
    }

    public func run(
        project: Project,
        serviceName: String,
        command: [String],
        detach: Bool = false,
        interactive: Bool = false,
        tty: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        environment: [String] = [],
        noDeps: Bool = false,
        removeOnExit: Bool = false,
        pullPolicy: PullPolicy = .missing
    ) async throws -> Int32 {
        guard let service = project.services[serviceName] else {
            throw ContainerizationError(.notFound, message: "Service '\(serviceName)' not found")
        }

        if !noDeps {
            let scoped = DependencyResolver.filterWithDependencies(services: project.services, selected: [serviceName])
            let dependencyServices = scoped.filter { $0.key != serviceName }
            if !dependencyServices.isEmpty {
                let dependencyProject = Project(
                    name: project.name,
                    services: dependencyServices,
                    networks: project.networks,
                    volumes: project.volumes
                )
                try await up(
                    project: dependencyProject,
                    services: Array(dependencyServices.keys),
                    detach: true,
                    noDeps: false,
                    removeOnExit: false,
                    pullPolicy: pullPolicy
                )
            }
        }

        let imageName = resolvedRunImageName(projectName: project.name, service: service)
        try await ensureComposeNetworks(project: project)
        try await buildImagesIfNeeded(project: project, services: [serviceName: service], progressHandler: nil)
        try await ensureImageAvailable(serviceName: serviceName, service: service, imageName: imageName, policy: pullPolicy)

        let mergedEnvironment = resolveRunEnvironment(base: service.environment, overrides: environment)
        let runContainerId = oneOffContainerId(projectName: project.name, serviceName: serviceName)
        let runService = makeOneOffRunService(
            service: service,
            command: command,
            workdir: workdir,
            environment: mergedEnvironment,
            containerName: runContainerId,
            tty: tty,
            interactive: interactive
        )

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        var containerConfig = try await createContainerConfiguration(
            project: project,
            serviceName: serviceName,
            service: runService,
            imageName: imageName,
            removeOnExit: removeOnExit
        )
        containerConfig = applyUserOverride(user: user, to: containerConfig)
        let createOptions = ContainerCreateOptions(autoRemove: removeOnExit)
        try await containerClient.create(
            configuration: containerConfig,
            options: createOptions,
            kernel: kernel
        )
        let container = try await containerClient.get(id: containerConfig.id)

        let stdio = processStdio(detach: detach, interactive: interactive, tty: tty)

        let process = try await containerClient.bootstrap(id: container.id, stdio: stdio)
        try await process.start()

        if detach {
            return 0
        }

        installProcessSignalForwarders(process: process)
        return try await process.wait()
    }

    nonisolated internal func installProcessSignalForwarders(
        process: any ClientProcess,
        installer: (@Sendable (Int32, @escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        let register = installer ?? defaultProcessSignalInstaller
        for signo in [SIGINT, SIGTERM] {
            register(signo) {
                Task {
                    do { try await process.kill(signo) } catch { /* ignore */ }
                }
            }
        }
    }

    private nonisolated func defaultProcessSignalInstaller(
        signo: Int32,
        action: @escaping @Sendable () -> Void
    ) {
        signal(signo, SIG_IGN)
        DispatchQueue.main.async {
            let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            src.setEventHandler(handler: action)
            src.resume()
            ExecSignalRetainer.retain(src)
        }
    }

    nonisolated internal func applyUserOverride(
        user: String?,
        to configuration: ContainerConfiguration
    ) -> ContainerConfiguration {
        guard let user, !user.isEmpty else { return configuration }
        var configuration = configuration
        configuration.initProcess.user = .raw(userString: user)
        return configuration
    }

    nonisolated internal func matchesDownTarget(
        projectName: String,
        expectedIds: Set<String>,
        container: ContainerSnapshot,
        removeOrphans: Bool
    ) -> Bool {
        if removeOrphans {
            if let proj = container.configuration.labels["com.apple.compose.project"] {
                return proj == projectName
            }
            return container.id.hasPrefix("\(projectName)_")
        }
        return expectedIds.contains(container.id)
    }

    nonisolated internal func resolvedRunImageName(projectName: String, service: Service) -> String {
        service.effectiveImageName(projectName: projectName)
    }

    nonisolated internal func processStdio(
        detach: Bool,
        interactive: Bool,
        tty: Bool
    ) -> [FileHandle?] {
        guard !detach else {
            return [nil, nil, nil]
        }

        let stdin: FileHandle? = interactive || tty ? FileHandle.standardInput : nil
        return [stdin, FileHandle.standardOutput, FileHandle.standardError]
    }

    nonisolated internal func makeOneOffRunService(
        service: Service,
        command: [String],
        workdir: String?,
        environment: [String: String],
        containerName: String,
        tty: Bool,
        interactive: Bool
        ) -> Service {
        Service(
            name: service.name,
            image: service.image,
            build: service.build,
            command: command.isEmpty ? service.command : command,
            entrypoint: service.entrypoint,
            commandCleared: command.isEmpty ? service.commandCleared : false,
            entrypointCleared: service.entrypointCleared,
            workingDir: workdir ?? service.workingDir,
            environment: environment,
            ports: [],
            volumes: service.volumes,
            networks: service.networks,
            networkMode: service.networkMode,
            networkAliases: service.networkAliases,
            dependsOn: service.dependsOn,
            dependsOnHealthy: service.dependsOnHealthy,
            dependsOnStarted: service.dependsOnStarted,
            dependsOnCompletedSuccessfully: service.dependsOnCompletedSuccessfully,
            healthCheck: service.healthCheck,
            deploy: service.deploy,
            restart: service.restart,
            containerName: containerName,
            profiles: service.profiles,
            labels: service.labels,
            extraHosts: service.extraHosts,
            cpus: service.cpus,
            memory: service.memory,
            tty: tty,
            stdinOpen: interactive
        )
    }

    nonisolated internal func managedVolumeNamesForRemoval(project: Project) -> [String] {
        var volumeNames = Set<String>()

        for (logicalName, volume) in project.volumes where !volume.external {
            volumeNames.insert(resolvedProjectVolumeName(project: project, logicalName: logicalName))
        }

        for service in project.services.values {
            for mount in service.volumes where mount.type == .volume && !mount.source.isEmpty {
                if let volume = project.volumes[mount.source], volume.external {
                    continue
                }
                volumeNames.insert(resolvedProjectVolumeName(project: project, logicalName: mount.source))
            }
        }

        return volumeNames.sorted()
    }

    internal func resolveRunEnvironment(base: [String: String], overrides: [String]) -> [String: String] {
        var result = base
        for override in overrides {
            let parts = override.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
                continue
            }

            let key = String(override)
            if let value = ProcessInfo.processInfo.environment[key] {
                result[key] = value
            }
        }
        return result
    }

    nonisolated internal func resolvedProcessEnvironment(
        imageEnvironment: [String],
        serviceEnvironment: [String: String]
    ) -> [String] {
        var merged: [String: String] = [:]

        for entry in imageEnvironment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            merged[key] = value
        }

        for (key, value) in serviceEnvironment {
            merged[key] = value
        }

        return merged.map { "\($0.key)=\($0.value)" }.sorted()
    }

    internal func oneOffContainerId(projectName: String, serviceName: String) -> String {
        "\(projectName)_\(serviceName)_run_\(UUID().uuidString.lowercased())"
    }

    /// Check health of services
    public func checkHealth(
        project: Project,
        services: [String] = []
    ) async throws -> [String: Bool] {
        var healthStatus: [String: Bool] = [:]
        let targetServices = services.isEmpty ? Array(project.services.keys) : services
        for serviceName in targetServices {
            guard let service = project.services[serviceName], service.healthCheck != nil else { continue }
            do {
                healthStatus[serviceName] = try await runHealthCheckOnce(project: project, serviceName: serviceName, service: service)
            } catch {
                healthStatus[serviceName] = false
            }
        }
        return healthStatus
    }

    /// Result of a remove operation
    public struct RemoveResult: Sendable {
        public let removedContainers: [String]
    }

    /// Remove containers for specified services
    public func remove(
        project: Project,
        services: [String],
        force: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws -> RemoveResult {
        log.info("Removing containers for project '\(project.name)'")

        // Determine which containers to remove
        var targetServices = services

        // If no services specified, remove all services in the project
        if targetServices.isEmpty {
            targetServices = Array(project.services.keys)
        }

        // Get expected container IDs for target services
        let expectedIds: Set<String> = Set(targetServices.compactMap { serviceName in
            guard let service = project.services[serviceName] else { return nil }
            return service.containerName ?? "\(project.name)_\(serviceName)"
        })

        var removedContainers: [String] = []

        do {
            let all = try await containerClient.list()
            let targets: [ContainerSnapshot] = all.filter { container in
                // Check by label first
                if let proj = container.configuration.labels["com.apple.compose.project"],
                   proj == project.name,
                   let svc = container.configuration.labels["com.apple.compose.service"],
                   targetServices.contains(svc) {
                    return true
                }
                // Fallback to ID matching
                return expectedIds.contains(container.id)
            }

            for container in targets {
                do {
                    // Check if container is running
                    if container.status == .running {
                        if force {
                            // Force stop and remove
                            try await containerClient.stop(id: container.id)
                        } else {
                            log.warning("Container '\(container.id)' is running, skipping (use -f to force)")
                            continue
                        }
                    }

                    // Remove the container
                    try await containerClient.delete(id: container.id)
                    removedContainers.append(container.id)
                    log.info("Removed container '\(container.id)'")

                } catch {
                    log.warning("Failed to remove container '\(container.id)': \(error)")
                }
            }
        } catch {
            log.warning("Failed to enumerate containers: \(error)")
        }

        log.info("Removed \(removedContainers.count) containers for project '\(project.name)'")
        return RemoveResult(removedContainers: removedContainers)
    }
}
