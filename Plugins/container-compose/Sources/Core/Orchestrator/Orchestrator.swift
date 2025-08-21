//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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
import ContainerClient
import ContainerNetworkService
import Containerization
import ContainerizationError
import ContainerizationOS
import Logging

#if os(macOS)
import Darwin
#else
import Glibc
#endif
import ContainerizationOCI

// MARK: - HealthCheckRunner

public protocol HealthCheckRunner: Sendable {
    func execute(container: ClientContainer, healthCheck: HealthCheck, log: Logger) async -> Bool
}

public struct DefaultHealthCheckRunner: HealthCheckRunner {
    public init() {}
    public func execute(container: ClientContainer, healthCheck: HealthCheck, log: Logger) async -> Bool {
        do {
            let processId = "healthcheck-\(UUID().uuidString)"
            let procConfig = ProcessConfiguration(
                executable: healthCheck.test[0],
                arguments: Array(healthCheck.test.dropFirst()),
                environment: [],
                workingDirectory: "/"
            )
            let process = try await container.createProcess(
                id: processId,
                configuration: procConfig,
                stdio: [nil, nil, nil]
            )
            let timeoutSeconds = Int(healthCheck.timeout ?? 30)
            try await process.start()
            let exitCode = try await withTimeoutGlobal(seconds: timeoutSeconds) {
                try await process.wait()
            }
            return exitCode == 0
        } catch {
            log.debug("Health check failed for container \(container.id): \(error)")
            return false
        }
    }
}

/// Manages the lifecycle of services in a compose project.
///
/// The Orchestrator is responsible for:
/// - Starting and stopping services in dependency order
/// - Managing container lifecycle (create, start, stop, remove)
/// - Tracking container state within a project
/// - Handling service logs and command execution
///
/// All operations are thread-safe through the actor model.
public actor Orchestrator {
    private let log: Logger
    private var projectState: [String: ProjectState] = [:]
    private var healthMonitors: [String: [String: Task<Void, Never>]] = [:] // project -> service -> task
    private var healthWaiters: [String: [String: [CheckedContinuation<Void, Error>]]] = [:]
    private let healthRunner: HealthCheckRunner
    
    /// State of a project
    private struct ProjectState {
        var containers: [String: ContainerState] = [:]
    }
    
    /// State of a container in a project
    private struct ContainerState {
        let serviceName: String
        let containerID: String
        let containerName: String
        var status: ContainerStatus
    }
    
    /// Container status
    private enum ContainerStatus {
        case created
        case running
        case stopped
        case removed
        case healthy
        case unhealthy
        case starting  // health: starting - not yet healthy
    }
    
    public init(log: Logger, healthRunner: HealthCheckRunner = DefaultHealthCheckRunner()) {
        self.log = log
        self.healthRunner = healthRunner
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
        progressHandler: ProgressUpdateHandler? = nil
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
        
        // Resolve dependencies
        let resolution = try DependencyResolver.resolve(services: targetServices)
        log.debug("Service start order: \(resolution.startOrder.joined(separator: ", "))")
        
        // Create named volumes if they don't exist
        try await createNamedVolumes(project: project, progressHandler: progressHandler)
        
        // Initialize project state
        if projectState[project.name] == nil {
            projectState[project.name] = ProjectState()
        }
        
        // Start services in dependency order
        let totalSteps = resolution.startOrder.count * 2 // Create + start for each
        var currentStep = 0
        
        for group in resolution.parallelGroups {
            // Start services in parallel within each group
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for serviceName in group {
                    guard let service = targetServices[serviceName] else { continue }
                    
                    let capturedProject = project
                    let capturedService = service
                    let capturedForceRecreate = forceRecreate
                    let capturedNoRecreate = noRecreate
                    let capturedDetach = detach
                    let capturedProgressHandler = progressHandler
                    
                    taskGroup.addTask { [weak self] in
                        guard let self else { return }
                        try await self.startService(
                            project: capturedProject,
                            service: capturedService,
                            forceRecreate: capturedForceRecreate,
                            noRecreate: capturedNoRecreate,
                            detach: capturedDetach,
                            progressHandler: capturedProgressHandler
                        )
                    }
                }
                
                // Wait for all services in the group to start
                try await taskGroup.waitForAll()
                currentStep += group.count * 2
                
                await progressHandler?([
                    .setTasks(currentStep),
                    .setTotalTasks(totalSteps)
                ])
            }
        }
        
        // Optionally remove orphan containers not in current project services
        if removeOrphans {
            let keep = Set(targetServices.keys)
            try await removeOrphanContainers(project: project, keepServices: keep)
        }
        
        log.info("Project '\(project.name)' started successfully")
    }
    
    /// Stop and remove services in a project.
    ///
    /// Services are stopped in reverse dependency order to ensure dependent
    /// services are stopped before their dependencies. All containers are
    /// removed after being stopped.
    ///
    /// - Parameters:
    ///   - project: The project containing service definitions
    ///   - removeVolumes: Whether to remove associated volumes (not implemented)
    ///   - progressHandler: Optional handler for progress updates
    /// - Throws: `ContainerizationError` if container operations fail
    public func down(
        project: Project,
        removeVolumes: Bool = false,
        removeOrphans: Bool = false,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        log.info("Stopping project '\(project.name)'")
        
        guard let state = projectState[project.name] else {
            log.info("Project '\(project.name)' has no running containers")
            return
        }
        
        // Get services in reverse dependency order
        let resolution = try DependencyResolver.resolve(services: project.services)
        let stopOrder = resolution.stopOrder
        
        let totalSteps = state.containers.count
        var currentStep = 0
        
        // Stop containers in reverse order
        for serviceName in stopOrder {
            if let containerState = state.containers[serviceName] {
                try await stopAndRemoveContainer(
                    containerID: containerState.containerID,
                    containerName: containerState.containerName
                )
                
                currentStep += 1
                await progressHandler?([
                    .setTasks(currentStep),
                    .setTotalTasks(totalSteps)
                ])
            }
        }
        
        // Cancel health monitors for this project
        cancelHealthMonitors(projectName: project.name)

        // Optionally remove volumes
        if removeVolumes {
            try await removeNamedVolumes(project: project, progressHandler: progressHandler)
        }

        // Optionally remove orphans remaining for this project prefix
        if removeOrphans {
            try await removeOrphanContainers(project: project, keepServices: Set(project.services.keys))
        }

        // Clear project state
        projectState[project.name] = nil
        
        log.info("Project '\(project.name)' stopped and removed")
    }
    
    /// List containers in a project.
    ///
    /// Returns the current status of all services defined in the project,
    /// including services that have no running containers.
    ///
    /// - Parameter project: The project to query
    /// - Returns: Array of service status information
    /// - Throws: `ContainerizationError` if unable to query containers
    public func ps(project: Project) async throws -> [ServiceStatus] {
        var statuses: [ServiceStatus] = []
        
        // Get all containers
        let containers = try await ClientContainer.list()
        
        for (serviceName, service) in project.services {
            let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
            
            if let container = containers.first(where: { $0.id == containerName }) {
                var statusText = container.status.rawValue
                
                // Check for health status if health check is defined
                if service.healthCheck != nil {
                    if let state = projectState[project.name],
                       let containerState = state.containers[serviceName] {
                        switch containerState.status {
                        case .healthy:
                            statusText = "\(statusText) (healthy)"
                        case .unhealthy:
                            statusText = "\(statusText) (unhealthy)"
                        case .starting:
                            statusText = "\(statusText) (health: starting)"
                        default:
                            break
                        }
                    } else if container.status == RuntimeStatus.running {
                        // If running but no health state, execute a check
                        let isHealthy = await healthRunner.execute(
                            container: container,
                            healthCheck: service.healthCheck!,
                            log: log
                        )
                        statusText = "\(statusText) (\(isHealthy ? "healthy" : "unhealthy"))"
                    }
                }
                
                statuses.append(ServiceStatus(
                    name: serviceName,
                    containerID: container.id,
                    containerName: containerName,
                    status: statusText,
                    ports: formatPorts(service.ports),
                    image: service.image ?? "unknown"
                ))
            } else {
                // Service defined but no container
                statuses.append(ServiceStatus(
                    name: serviceName,
                    containerID: "",
                    containerName: containerName,
                    status: "not created",
                    ports: "",
                    image: service.image ?? "unknown"
                ))
            }
        }
        
        return statuses
    }
    
    /// Start stopped services in a project
    public func start(
        project: Project,
        services: [String] = [],
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        log.info("Starting services in project '\(project.name)'")
        
        // Filter services if specific ones requested
        let targetServices = services.isEmpty ? project.services : 
            DependencyResolver.filterWithDependencies(services: project.services, selected: services)
        
        // Resolve dependencies
        let resolution = try DependencyResolver.resolve(services: targetServices)
        log.debug("Service start order: \(resolution.startOrder.joined(separator: ", "))")
        
        // Get existing containers
        let containers = try await ClientContainer.list()
        
        var totalSteps = 0
        var toStart: [(String, Service, ClientContainer)] = []
        
        // Find containers that need starting
        for serviceName in resolution.startOrder {
            guard let service = targetServices[serviceName] else { continue }
            let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
            
            if let container = containers.first(where: { $0.id == containerName }) {
                if container.status != RuntimeStatus.running {
                    toStart.append((serviceName, service, container))
                    totalSteps += 1
                }
            }
        }
        
        if toStart.isEmpty {
            log.info("All services are already running")
            return
        }
        
        var currentStep = 0
        
        // Start containers in dependency order
        for (serviceName, _, container) in toStart {
            await progressHandler?([
                .setDescription("Starting service '\(serviceName)'")
            ])
            
            let process = try await container.bootstrap(stdio: [nil, nil, nil])
            
            // Start in detached mode
            try await process.start()
            
            currentStep += 1
            await progressHandler?([
                .setTasks(currentStep),
                .setTotalTasks(totalSteps)
            ])
        }
        
        log.info("Started \(toStart.count) service(s)")
    }
    
    /// Stop running services in a project
    public func stop(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        log.info("Stopping services in project '\(project.name)'")
        
        // Filter services if specific ones requested
        let targetServices = services.isEmpty ? project.services :
            DependencyResolver.filterWithDependencies(services: project.services, selected: services)
        
        // Resolve dependencies
        let resolution = try DependencyResolver.resolve(services: targetServices)
        let stopOrder = resolution.stopOrder
        
        // Get existing containers
        let containers = try await ClientContainer.list()
        
        var totalSteps = 0
        var toStop: [(String, Service, ClientContainer)] = []
        
        // Find containers that need stopping
        for serviceName in stopOrder {
            guard let service = targetServices[serviceName] else { continue }
            let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
            
            if let container = containers.first(where: { $0.id == containerName }) {
                if container.status == RuntimeStatus.running {
                    toStop.append((serviceName, service, container))
                    totalSteps += 1
                }
            }
        }
        
        if toStop.isEmpty {
            log.info("No services are running")
            return
        }
        
        var currentStep = 0
        
        // Stop containers in reverse dependency order
        for (serviceName, _, container) in toStop {
            await progressHandler?([
                .setDescription("Stopping service '\(serviceName)'")
            ])
            
            let stopOptions = ContainerStopOptions(
                timeoutInSeconds: Int32(timeout),
                signal: SIGTERM
            )
            try await container.stop(opts: stopOptions)
            
            currentStep += 1
            await progressHandler?([
                .setTasks(currentStep),
                .setTotalTasks(totalSteps)
            ])
        }
        
        log.info("Stopped \(toStop.count) service(s)")
    }
    
    /// Restart services in a project
    public func restart(
        project: Project,
        services: [String] = [],
        timeout: Int = 10,
        progressHandler: ProgressUpdateHandler? = nil
    ) async throws {
        log.info("Restarting services in project '\(project.name)'")
        
        // Stop services first
        try await stop(
            project: project,
            services: services,
            timeout: timeout,
            progressHandler: progressHandler
        )
        
        // Small delay between stop and start
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Start services
        try await start(
            project: project,
            services: services,
            progressHandler: progressHandler
        )
        
        log.info("Restarted services for project '\(project.name)'")
    }
    
    /// Get logs from services
    public func logs(
        project: Project,
        services: [String] = [],
        follow: Bool = false,
        tail: Int? = nil,
        timestamps: Bool = false
    ) async throws -> AsyncThrowingStream<LogEntry, Error> {
        // Filter services if specific ones requested
        let targetServices = services.isEmpty ? Array(project.services.keys) : services
        
        // Find containers for requested services
        let containers = try await ClientContainer.list()
        var serviceContainers: [(String, ClientContainer)] = []
        
        for serviceName in targetServices {
            guard let service = project.services[serviceName] else {
                log.warning("Service '\(serviceName)' not found in project")
                continue
            }
            
            let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
            
            if let container = containers.first(where: { $0.id == containerName }) {
                serviceContainers.append((serviceName, container))
            } else {
                log.warning("Container for service '\(serviceName)' not found")
            }
        }
        
        if serviceContainers.isEmpty {
            throw ContainerizationError(
                .notFound,
                message: "No containers found for requested services"
            )
        }
        
        // Return multiplexed log stream
        return AsyncThrowingStream { continuation in
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for (serviceName, container) in serviceContainers {
                        group.addTask { [weak self] in
                            do {
                                // Get log file handles using existing container logs API
                                let logHandles = try await container.logs()
                                let stdoutHandle = logHandles[0]  // stdout
                                
                                if let numLines = tail {
                                    // Read last N lines if tail is specified
                                    var buffer = Data()
                                    let size = try stdoutHandle.seekToEnd()
                                    var offset = size
                                    var lines: [String] = []
                                    
                                    while offset > 0, lines.count < numLines {
                                        let readSize = min(1024, offset)
                                        offset -= readSize
                                        try stdoutHandle.seek(toOffset: offset)
                                        
                                        let data = stdoutHandle.readData(ofLength: Int(readSize))
                                        buffer.insert(contentsOf: data, at: 0)
                                        
                                        if let chunk = String(data: buffer, encoding: .utf8) {
                                            lines = chunk.components(separatedBy: .newlines)
                                            lines = lines.filter { !$0.isEmpty }
                                        }
                                    }
                                    
                                    lines = Array(lines.suffix(numLines))
                                    for line in lines {
                                        let entry = LogEntry(
                                            serviceName: serviceName,
                                            timestamp: Date(),
                                            message: line,
                                            stream: .stdout
                                        )
                                        continuation.yield(entry)
                                    }
                                } else {
                                    // Read all logs
                                    if let data = try stdoutHandle.readToEnd(),
                                       let str = String(data: data, encoding: .utf8) {
                                        let lines = str.components(separatedBy: .newlines)
                                        for line in lines where !line.isEmpty {
                                            let entry = LogEntry(
                                                serviceName: serviceName,
                                                timestamp: Date(),
                                                message: line,
                                                stream: .stdout
                                            )
                                            continuation.yield(entry)
                                        }
                                    }
                                }
                                
                                if follow {
                                    // Set up following using readabilityHandler like ContainerLogs
                                    _ = try stdoutHandle.seekToEnd()
                                    stdoutHandle.readabilityHandler = { handle in
                                        let data = handle.availableData
                                        if data.isEmpty {
                                            // Container might have restarted
                                            do {
                                                _ = try stdoutHandle.seekToEnd()
                                            } catch {
                                                stdoutHandle.readabilityHandler = nil
                                                return
                                            }
                                        }
                                        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                                            let lines = str.components(separatedBy: .newlines)
                                            for line in lines where !line.isEmpty {
                                                let entry = LogEntry(
                                                    serviceName: serviceName,
                                                    timestamp: Date(),
                                                    message: line,
                                                    stream: .stdout
                                                )
                                                continuation.yield(entry)
                                            }
                                        }
                                    }
                                }
                            } catch {
                                self?.log.error("Failed to get logs for service '\(serviceName)': \(error)")
                            }
                        }
                    }
                    
                    // Wait for all log tasks
                    await group.waitForAll()
                }
                
                if !follow {
                    continuation.finish()
                }
            }
        }
    }
    
    /// Execute a command in a running service container
    public func exec(
        project: Project,
        serviceName: String,
        command: [String],
        detach: Bool = false,
        interactive: Bool = false,
        tty: Bool = false,
        user: String? = nil,
        workdir: String? = nil,
        environment: [String] = []
    ) async throws -> Int32 {
        guard let service = project.services[serviceName] else {
            throw ContainerizationError(
                .notFound,
                message: "Service '\(serviceName)' not found in project"
            )
        }
        
        let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
        
        // Find container
        let containers = try await ClientContainer.list()
        guard let container = containers.first(where: { $0.id == containerName }) else {
            throw ContainerizationError(
                .notFound,
                message: "Container for service '\(serviceName)' not found"
            )
        }
        
        // Check if container is running
        if container.status != RuntimeStatus.running {
            throw ContainerizationError(
                .invalidState,
                message: "Container for service '\(serviceName)' is not running"
            )
        }
        
        // Get container instance
        let containerInstance = try await ClientContainer.get(id: container.id)
        
        // Create process configuration for exec
        let executable = command.first ?? "/bin/sh"
        let arguments = command.count > 1 ? Array(command.dropFirst()) : []
        
        var procConfig = ProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workdir ?? "/",
            terminal: tty
        )
        
        // Set user if specified
        if let user = user {
            procConfig.user = .raw(userString: user)
        }
        
        // Determine stdio based on interactive mode
        let stdin = interactive ? FileHandle.standardInput : nil
        let stdout = FileHandle.standardOutput
        let stderr = FileHandle.standardError
        
        // Create and start process using the same pattern as ContainerExec
        let process = try await containerInstance.createProcess(
            id: UUID().uuidString.lowercased(),
            configuration: procConfig,
            stdio: [stdin, stdout, stderr]
        )
        
        // Handle process I/O based on flags
        if detach {
            try await process.start()
            return 0
        } else {
            // Start process (stdio was already passed during createProcess)
            try await process.start()
            
            // Wait for process to complete
            let exitCode = try await process.wait()
            return exitCode
        }
    }
    
    // MARK: - Private Methods
    
    private func createNamedVolumes(
        project: Project,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        guard !project.volumes.isEmpty else { return }
        
        await progressHandler?([
            .setDescription("Creating volumes")
        ])
        
        for (volumeName, volume) in project.volumes {
            // Skip external volumes
            if volume.external {
                log.debug("Skipping external volume '\(volumeName)'")
                continue
            }
            
            // Check if volume already exists
            do {
                let existingVolumes = try await ClientVolume.list()
                if existingVolumes.contains(where: { $0.name == volumeName }) {
                    log.debug("Volume '\(volumeName)' already exists")
                    continue
                }
            } catch {
                // If listing fails, attempt to create anyway
                log.debug("Could not list volumes: \(error)")
            }
            
            // Create the volume
            do {
                _ = try await ClientVolume.create(
                    name: volumeName
                )
                log.info("Created volume '\(volumeName)'")
            } catch {
                // If volume already exists, that's fine
                if error.localizedDescription.contains("already exists") {
                    log.debug("Volume '\(volumeName)' already exists")
                } else {
                    log.error("Failed to create volume '\(volumeName)': \(error)")
                    throw error
                }
            }
        }
    }
    
    private func startService(
        project: Project,
        service: Service,
        forceRecreate: Bool,
        noRecreate: Bool,
        detach: Bool,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        let containerName = service.containerName ?? "\(project.name)_\(service.name)"

        await progressHandler?([
            .setDescription("Starting service '\(service.name)'")
        ])

        // If this service requires dependencies to be started, wait for them
        if !service.dependsOnStarted.isEmpty {
            for dep in service.dependsOnStarted {
                try await awaitServiceStarted(project: project, serviceName: dep, deadlineSeconds: 60)
            }
        }

        // If this service requires dependencies to be healthy, wait for them
        if !service.dependsOnHealthy.isEmpty {
            for dep in service.dependsOnHealthy {
                let deadline = computeHealthDeadline(healthCheck: project.services[dep]?.healthCheck)
                try await awaitServiceHealthy(project: project, serviceName: dep, deadlineSeconds: deadline)
            }
        }

        // If this service requires dependencies to complete successfully, wait for them
        if !service.dependsOnCompletedSuccessfully.isEmpty {
            for dep in service.dependsOnCompletedSuccessfully {
                log.warning("depends_on condition 'service_completed_successfully' for '\(dep)' cannot verify exit code; will only wait until container stops")
                try await awaitServiceCompleted(project: project, serviceName: dep, deadlineSeconds: 300)
            }
        }
        
        // Check if container already exists
        let existingContainer = try? await ClientContainer.get(id: containerName)
        
        if let existing = existingContainer {
            if forceRecreate {
                // Remove existing container
                try await stopAndRemoveContainer(
                    containerID: existing.id,
                    containerName: containerName
                )
            } else if noRecreate {
                // Just start existing container
                if existing.status != RuntimeStatus.running {
                    let process = try await existing.bootstrap(stdio: [nil, nil, nil])
                    
                    // Start container in detached mode (compose always manages containers detached)
                    try await process.start()
                }
                return
            } else {
                // Check if recreation needed (config changed)
                // For now, just start if stopped
                if existing.status != RuntimeStatus.running {
                    let process = try await existing.bootstrap(stdio: [nil, nil, nil])
                    
                    // Start container in detached mode (compose always manages containers detached)
                    try await process.start()
                }
                return
            }
        }
        
        // Create new container
        let containerConfig = try await createContainerConfig(
            project: project,
            service: service,
            containerName: containerName,
            progressHandler: progressHandler
        )
        
        // Get default kernel for the platform
        let kernel = try await ClientKernel.getDefaultKernel(for: SystemPlatform.current)
        
        let container: ClientContainer
        do {
            container = try await ClientContainer.create(
                configuration: containerConfig,
                options: ContainerCreateOptions(autoRemove: false),
                kernel: kernel
            )
        } catch {
            log.error("Failed to create container for service '\(service.name)': \(error)")
            throw error
        }
        
        // Update project state
        projectState[project.name]!.containers[service.name] = ContainerState(
            serviceName: service.name,
            containerID: container.id,
            containerName: containerName,
            status: .created
        )
        
        // Start container using the same logic as ContainerStart
        let process = try await container.bootstrap(stdio: [nil, nil, nil])
        
        // Start container in detached mode (compose always manages containers detached)
        try await process.start()
        
        // Update status
        projectState[project.name]!.containers[service.name]!.status = service.healthCheck == nil ? .running : .starting

        // Informative DNS log: services are reachable by their container ID
        let dnsName = containerName
        log.info("Service '\(service.name)' reachable via DNS name: \(dnsName)")

        // Check health if defined
        if let healthCheck = service.healthCheck {
            await progressHandler?([
                .setDescription("Checking health for '\(service.name)'")
            ])
            
            // Wait for start period
            let startPeriod = healthCheck.startPeriod ?? 0
            if startPeriod > 0 {
                try await Task.sleep(nanoseconds: UInt64(startPeriod) * 1_000_000_000)
            }
            
            // Execute health check with retries/interval (initial gating)
            let attempts = max(1, (healthCheck.retries ?? 0) + 1)
            var ok = false
            for i in 1...attempts {
                let isHealthy = await healthRunner.execute(container: container, healthCheck: healthCheck, log: log)
                if isHealthy { ok = true; break }
                if i < attempts {
                    let interval = healthCheck.interval ?? 0
                    if interval > 0 { try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) }
                }
            }
            projectState[project.name]!.containers[service.name]!.status = ok ? .healthy : .unhealthy
            if ok { notifyHealthy(projectName: project.name, serviceName: service.name) }
            if !ok { log.warning("Service '\(service.name)' failed health checks") }

            // Start background health monitor
            startHealthMonitor(project: project, service: service, containerID: container.id, healthCheck: healthCheck)
        }
        
        await progressHandler?([
            .setDescription("Service '\(service.name)' started")
        ])
    }
    
    private func createContainerConfig(
        project: Project,
        service: Service,
        containerName: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> ContainerConfiguration {
        guard let image = service.image else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Service '\(service.name)' has no image specified"
            )
        }
        
        // Create process configuration
        // Determine executable and arguments
        let executable: String
        let arguments: [String]
        if let entrypoint = service.entrypoint, !entrypoint.isEmpty {
            executable = entrypoint[0]
            arguments = Array(entrypoint.dropFirst()) + (service.command ?? [])
        } else if let command = service.command, !command.isEmpty {
            executable = command[0]
            arguments = Array(command.dropFirst())
        } else {
            // Use shell as default
            executable = "/bin/sh"
            arguments = []
        }
        
        // Convert environment to array format
        let environment = service.environment.map { key, value in
            "\(key)=\(value)"
        }
        
        let procConfig = ProcessConfiguration(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: service.workingDir ?? "/"
        )
        
        // Fetch the image using the same approach as Utility.containerConfigFromFlags
        await progressHandler?([
            .setDescription("Fetching image '\(image)'"),
            .setItemsName("blobs")
        ])
        
        let fetchedImage = try await ClientImage.fetch(
            reference: image,
            platform: .current,
            scheme: .https
        )
        
        // Unpack the fetched image
        await progressHandler?([
            .setDescription("Unpacking image '\(image)'"),
            .setItemsName("entries")
        ])
        
        _ = try await fetchedImage.getCreateSnapshot(
            platform: .current,
            progressUpdate: nil
        )
        
        let imageDescription = fetchedImage.description
        
        // Create container configuration
        var config = ContainerConfiguration(
            id: containerName,
            image: imageDescription,
            process: procConfig
        )
        
        // Set resource limits
        if let cpusString = service.cpus,
           let cpus = Double(cpusString) {
            config.resources.cpus = Int(cpus)
        }
        
        if let memoryString = service.memory {
            config.resources.memoryInBytes = UInt64(try parseMemory(memoryString))
        }
        
        // Set mounts
        config.mounts = service.volumes.compactMap { mount in
            createFilesystem(from: mount)
        }
        
        // Set port mappings
        config.publishedPorts = service.ports.map { port in
            PublishPort(
                hostAddress: port.hostIP ?? "0.0.0.0",
                hostPort: Int(port.hostPort) ?? 0,
                containerPort: Int(port.containerPort) ?? 0,
                proto: PublishProtocol(port.portProtocol) ?? .tcp
            )
        }
        
        // Set labels
        config.labels = service.labels
        
        // Set networks - default network if none specified
        let networkNames = service.networks.isEmpty ? ["default"] : service.networks

        config.networks = networkNames.map { networkName in
            AttachmentConfiguration(
                network: networkName,
                options: AttachmentOptions(hostname: containerName)
            )
        }
        
        return config
    }
    
    private func createFilesystem(from volumeMount: VolumeMount) -> Filesystem? {
        switch volumeMount.type {
        case .bind:
            // Check if source exists
            if !FileManager.default.fileExists(atPath: volumeMount.source) {
                log.warning("Volume source '\(volumeMount.source)' does not exist, skipping")
                return nil
            }
            
            let options: MountOptions = volumeMount.readOnly ? ["ro"] : []
            
            return Filesystem(
                type: .virtiofs,
                source: volumeMount.source,
                destination: volumeMount.target,
                options: options
            )
            
        case .tmpfs:
            // Use tmpfs for ephemeral storage
            return Filesystem(
                type: .tmpfs,
                source: "tmpfs",
                destination: volumeMount.target,
                options: []
            )
            
        case .volume:
            // Use named volume
            let options: MountOptions = volumeMount.readOnly ? ["ro"] : []
            
            // Use default values for volume parameters
            return Filesystem(
                type: .volume(name: volumeMount.source, format: "ext4", cache: .auto, sync: .full),
                source: volumeMount.source,
                destination: volumeMount.target,
                options: options
            )
        }
    }
    
    private func parseMemory(_ memoryString: String) throws -> Int64 {
        let pattern = #"^(\d+)([KMGT]?)B?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: memoryString, range: NSRange(memoryString.startIndex..., in: memoryString)),
              let valueRange = Range(match.range(at: 1), in: memoryString),
              let value = Int64(memoryString[valueRange]) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Invalid memory specification: \(memoryString)"
            )
        }
        
        let unitRange = Range(match.range(at: 2), in: memoryString)
        let unit = unitRange.map { String(memoryString[$0]).uppercased() } ?? ""
        
        let multiplier: Int64
        switch unit {
        case "K":
            multiplier = 1024
        case "M":
            multiplier = 1024 * 1024
        case "G":
            multiplier = 1024 * 1024 * 1024
        case "T":
            multiplier = 1024 * 1024 * 1024 * 1024
        default:
            multiplier = 1
        }
        
        return value * multiplier
    }
    
    
    private func stopAndRemoveContainer(containerID: String, containerName: String) async throws {
        do {
            let container = try await ClientContainer.get(id: containerID)
            
            // Stop if running
            if container.status == RuntimeStatus.running {
                let stopOptions = ContainerStopOptions(
                    timeoutInSeconds: 10,
                    signal: SIGTERM
                )
                try await container.stop(opts: stopOptions)
            }
            
            // Remove
            try await container.delete()
        } catch {
            log.warning("Failed to stop/remove container '\(containerName)': \(error)")
        }
    }

    /// Remove orphan containers that match the project's prefix but are not part of `keepServices`.
    private func removeOrphanContainers(project: Project, keepServices: Set<String>) async throws {
        let prefix = project.name + "_"
        let containers = try await ClientContainer.list()
        for c in containers {
            guard c.id.hasPrefix(prefix) else { continue }
            // infer service name from suffix
            let serviceName = String(c.id.dropFirst(prefix.count))
            if !keepServices.contains(serviceName) {
                log.info("Removing orphan container '\(c.id)'")
                do { try await c.delete() } catch {
                    log.warning("Failed to remove orphan container '\(c.id)': \(error)")
                }
            }
        }
    }
    
    private func formatPorts(_ ports: [PortMapping]) -> String {
        return ports.map { port in
            if let hostIP = port.hostIP {
                return "\(hostIP):\(port.hostPort):\(port.containerPort)/\(port.portProtocol)"
            } else {
                return "\(port.hostPort):\(port.containerPort)/\(port.portProtocol)"
            }
        }.joined(separator: ", ")
    }
    
    /// Execute health check for a container.
    ///
    /// Runs the health check command inside the container and returns whether it succeeded.
    /// A health check is considered successful if the command exits with code 0.
    ///
    /// - Parameters:
    ///   - container: The container to check
    ///   - healthCheck: The health check configuration
    /// - Returns: `true` if the health check passed (exit code 0), `false` otherwise
    // Background health monitor
    private func startHealthMonitor(project: Project, service: Service, containerID: String, healthCheck: HealthCheck) {
        let projName = project.name
        var serviceMap = healthMonitors[projName] ?? [:]
        // Cancel existing
        if let existing = serviceMap[service.name] { existing.cancel() }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                // Wait for start_period already handled; begin periodic checks
                var consecutiveFailures = 0
                while true {
                    // Check container is still present and running
                    guard let container = try? await ClientContainer.get(id: containerID) else { return }
                    if container.status != RuntimeStatus.running { return }

                    let ok = await self.healthRunner.execute(container: container, healthCheck: healthCheck, log: self.log)
                    await self.updateHealthStatus(projectName: projName, serviceName: service.name, healthy: ok, retries: healthCheck.retries ?? 0)
                    if ok { consecutiveFailures = 0 } else {
                        consecutiveFailures += 1
                    }
                    let interval = max(1, Int(healthCheck.interval ?? 30))
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                }
            } catch {
                // Container listing or sleep failed; end monitor
                return
            }
        }
        serviceMap[service.name] = task
        healthMonitors[projName] = serviceMap
    }

    private func cancelHealthMonitors(projectName: String) {
        guard let map = healthMonitors[projectName] else { return }
        for (_, task) in map { task.cancel() }
        healthMonitors[projectName] = [:]
    }

    private func updateHealthStatus(projectName: String, serviceName: String, healthy: Bool, retries: Int) {
        if var state = projectState[projectName], var container = state.containers[serviceName] {
            container.status = healthy ? .healthy : .unhealthy
            state.containers[serviceName] = container
            projectState[projectName] = state
            if healthy { notifyHealthy(projectName: projectName, serviceName: serviceName) }
        }
    }

    private func notifyHealthy(projectName: String, serviceName: String) {
        guard var services = healthWaiters[projectName], var list = services[serviceName] else { return }
        services[serviceName] = []
        healthWaiters[projectName] = services
        for cont in list { cont.resume() }
        list.removeAll()
    }

    // Await a service becoming healthy; returns immediately if no healthcheck is defined
    public func awaitServiceHealthy(project: Project, serviceName: String, deadlineSeconds: Int) async throws {
        guard let svc = project.services[serviceName] else { return }
        // No healthcheck -> no gating, warn
        if svc.healthCheck == nil {
            log.warning("depends_on: service_healthy used for service '\(serviceName)' without healthcheck; not gating")
            return
        }
        if let state = projectState[project.name], let container = state.containers[serviceName] {
            if container.status == .healthy { return }
        }
        try await withTimeoutGlobal(seconds: deadlineSeconds) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Task { await self.addHealthWaiter(projectName: project.name, serviceName: serviceName, cont: cont) }
            }
        }
    }

    // Await a service to reach running state
    public func awaitServiceStarted(project: Project, serviceName: String, deadlineSeconds: Int) async throws {
        // Quick path via local state
        if let state = projectState[project.name]?.containers[serviceName] {
            switch state.status {
            case .running, .healthy, .starting: return
            default: break
            }
        }
        var remainingTicks = max(1, deadlineSeconds * 10) // 100ms ticks
        while remainingTicks > 0 {
            if let st = projectState[project.name]?.containers[serviceName] {
                switch st.status { case .running, .healthy, .starting: return; default: break }
            }
            if let container = try? await ClientContainer.get(id: project.name + "_" + serviceName), container.status == .running {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            remainingTicks -= 1
        }
        throw ContainerizationError(.timeout, message: "Service '\(serviceName)' did not start within \(deadlineSeconds)s")
    }

    // Await a service to complete (no exit code check available here)
    public func awaitServiceCompleted(project: Project, serviceName: String, deadlineSeconds: Int) async throws {
        var remainingTicks = max(1, deadlineSeconds * 5) // 200ms ticks
        while remainingTicks > 0 {
            if let st = projectState[project.name]?.containers[serviceName] {
                if st.status == .stopped || st.status == .removed { return }
            }
            if let container = try? await ClientContainer.get(id: project.name + "_" + serviceName), container.status != .running {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            remainingTicks -= 1
        }
        throw ContainerizationError(.timeout, message: "Service '\(serviceName)' did not complete within \(deadlineSeconds)s")
    }

    // Test hooks (internal) to drive waiter logic without a runtime
    func testSetServiceHealthy(project: Project, serviceName: String) {
        if projectState[project.name] == nil { projectState[project.name] = ProjectState() }
        if projectState[project.name]!.containers[serviceName] == nil {
            projectState[project.name]!.containers[serviceName] = ContainerState(serviceName: serviceName, containerID: "test-\(serviceName)", containerName: "\(project.name)_\(serviceName)", status: .starting)
        }
        projectState[project.name]!.containers[serviceName]!.status = .healthy
        notifyHealthy(projectName: project.name, serviceName: serviceName)
    }
    
    private func addHealthWaiter(projectName: String, serviceName: String, cont: CheckedContinuation<Void, Error>) {
        var svcMap = healthWaiters[projectName] ?? [:]
        var list = svcMap[serviceName] ?? []
        list.append(cont)
        svcMap[serviceName] = list
        healthWaiters[projectName] = svcMap
    }

    private func computeHealthDeadline(healthCheck: HealthCheck?) -> Int {
        guard let hc = healthCheck else { return 10 } // minimal wait if no healthcheck
        let start = Int(hc.startPeriod ?? 0)
        let interval = max(1, Int(hc.interval ?? 30))
        let attempts = max(1, (hc.retries ?? 0) + 1)
        // Budget: startPeriod + attempts * (max(timeout, interval))
        let timeout = max(1, Int(hc.timeout ?? 30))
        return start + attempts * max(timeout, interval)
    }
    
    /// Check health of services in a project.
    ///
    /// Executes health check commands for specified services (or all services with health checks)
    /// and returns their current health status. This is a one-time check, not continuous monitoring.
    ///
    /// - Parameters:
    ///   - project: The project containing service definitions
    ///   - services: Specific services to check (empty means all services with health checks)
    /// - Returns: Dictionary mapping service names to health status (true = healthy)
    /// - Throws: `ContainerizationError` if unable to execute health checks
    public func checkHealth(
        project: Project,
        services: [String] = []
    ) async throws -> [String: Bool] {
        var healthStatus: [String: Bool] = [:]
        
        // Get containers to check
        let containers = try await ClientContainer.list()
        let targetServices = services.isEmpty ? Array(project.services.keys) : services
        
        for serviceName in targetServices {
            guard let service = project.services[serviceName],
                  let healthCheck = service.healthCheck else {
                continue
            }
            
            let containerName = service.containerName ?? "\(project.name)_\(serviceName)"
            guard let container = containers.first(where: { $0.id == containerName }),
                  container.status == RuntimeStatus.running else {
                continue
            }
            
            // Execute health check
            let isHealthy = await healthRunner.execute(
                container: container,
                healthCheck: healthCheck,
                log: log
            )
            
            healthStatus[serviceName] = isHealthy
            
            // Update internal state
            if var state = projectState[project.name],
               var containerState = state.containers[serviceName] {
                containerState.status = isHealthy ? .healthy : .unhealthy
                state.containers[serviceName] = containerState
                projectState[project.name] = state
            }
        }
        
        return healthStatus
    }
    
    private func removeNamedVolumes(
        project: Project,
        progressHandler: ProgressUpdateHandler?
    ) async throws {
        guard !project.volumes.isEmpty else { return }
        
        await progressHandler?([
            .setDescription("Removing volumes")
        ])
        
        for (volumeName, volume) in project.volumes {
            // Skip external volumes
            if volume.external {
                log.debug("Skipping external volume '\(volumeName)'")
                continue
            }
            
            // Remove the volume
            do {
                _ = try await ClientVolume.delete(name: volumeName)
                log.info("Removed volume '\(volumeName)'")
            } catch {
                // If volume doesn't exist or can't be removed, log and continue
                log.warning("Failed to remove volume '\(volumeName)': \(error)")
            }
        }
    }
}

// MARK: - Service Status

public struct ServiceStatus: Sendable {
    public let name: String
    public let containerID: String
    public let containerName: String
    public let status: String
    public let ports: String
    public let image: String
}

// MARK: - Log Entry

public struct LogEntry: Sendable {
    public let serviceName: String
    public let timestamp: Date
    public let message: String
    public let stream: LogStream
    
    public enum LogStream: Sendable {
        case stdout
        case stderr
    }
}

// MARK: - Timeout helper

func withTimeoutGlobal<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw ContainerizationError(.timeout, message: "Operation timed out after \(seconds) seconds")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
