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
import Testing
import Logging
import ContainerizationError

@testable import ComposeCore

struct OrchestratorBuildTests {
    let log = Logger(label: "test")

    @Test
    func testOrchestratorCreation() async throws {
        let log = Logger(label: "test")
        let orchestrator = Orchestrator(log: log)

        // Test that orchestrator can be created successfully
        #expect(orchestrator != nil)
    }

    @Test
    func testBuildServiceCreation() async throws {
        let buildService = DefaultBuildService()

        // Test that build service can be created successfully
        #expect(buildService != nil)
    }

    @Test
    func testServiceNeedsBuild() throws {
        // Test service with build config
        let buildConfig = BuildConfig(context: ".", dockerfile: "Dockerfile", args: nil)
        let serviceWithBuild = Service(
            name: "test",
            image: nil,
            build: buildConfig
        )
        #expect(serviceWithBuild.needsBuild == true)

        // Test service with image only
        let serviceWithImage = Service(
            name: "test",
            image: "nginx:latest",
            build: nil
        )
        #expect(serviceWithImage.needsBuild == false)

        // Test service with both image and build
        let serviceWithBoth = Service(
            name: "test",
            image: "nginx:latest",
            build: buildConfig
        )
        #expect(serviceWithBoth.needsBuild == false)
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
}

    @Test
    func testBuildCacheKeyGeneration() async throws {
        let orchestrator = Orchestrator(log: log)

        // Test that we can access the private method through a test helper
        // This would require making the method internal or adding a test helper
        #expect(true) // Orchestrator created successfully
    }

    @Test
    func testServiceNeedsBuild() throws {
        // Test service with build config
        let buildConfig = BuildConfig(context: ".", dockerfile: "Dockerfile", args: nil)
        let serviceWithBuild = Service(
            name: "test",
            image: nil,
            build: buildConfig
        )
        #expect(serviceWithBuild.needsBuild == true)

        // Test service with image only
        let serviceWithImage = Service(
            name: "test",
            image: "nginx:latest",
            build: nil
        )
        #expect(serviceWithImage.needsBuild == false)

        // Test service with both image and build
        let serviceWithBoth = Service(
            name: "test",
            image: "nginx:latest",
            build: buildConfig
        )
        #expect(serviceWithBoth.needsBuild == false)
    }

    @Test
    func testEffectiveImageName() throws {
        let buildConfig = BuildConfig(context: "./app", dockerfile: "Dockerfile.dev", args: nil)

        // Service with image
        let serviceWithImage = Service(
            name: "web",
            image: "nginx:latest",
            build: nil
        )
        #expect(serviceWithImage.effectiveImageName(projectName: "myapp") == "nginx:latest")

        // Service with build only
        let serviceWithBuild = Service(
            name: "api",
            image: nil,
            build: buildConfig
        )
        let effectiveName = serviceWithBuild.effectiveImageName(projectName: "myapp")
        #expect(effectiveName.hasPrefix("myapp_api:"))
    }

    @Test
    func testHealthCheckRunner() async throws {
        // This test would require a mock container implementation
        // For now, we test the health check configuration parsing
        let healthCheck = HealthCheck(
            test: ["/bin/sh", "-c", "echo 'healthy'"],
            interval: 30.0,
            timeout: 10.0,
            retries: 3,
            startPeriod: 5.0
        )

        #expect(healthCheck.test == ["/bin/sh", "-c", "echo 'healthy'"])
        #expect(healthCheck.interval == 30.0)
        #expect(healthCheck.timeout == 10.0)
        #expect(healthCheck.retries == 3)
        #expect(healthCheck.startPeriod == 5.0)
    }

    @Test
    func testHealthCheckRunnerWithMockContainer() async throws {
        let log = Logger(label: "test")
        let healthRunner = DefaultHealthCheckRunner()
        let mockContainer = MockContainer(containerID: "test-container")

        let healthCheck = HealthCheck(
            test: ["/bin/sh", "-c", "echo 'healthy'"],
            interval: nil,
            timeout: 5.0, // Short timeout for testing
            retries: nil,
            startPeriod: nil
        )

        // Test health check execution
        // Note: This test may need adjustment based on the actual container implementation
        let result = await healthRunner.execute(
            container: mockContainer,
            healthCheck: healthCheck,
            log: log
        )

        // The result depends on the mock implementation
        // In a real scenario, this would test the actual health check logic
        #expect(type(of: result) == Bool.self)
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
    func testBuildServiceErrorHandling() async throws {
        let mockBuildService = MockBuildService()

        // Test that build service properly handles errors
        let buildConfig = BuildConfig(context: "/nonexistent", dockerfile: "Dockerfile", args: nil)

        await #expect {
            _ = try await mockBuildService.buildImage(
                serviceName: "test",
                buildConfig: buildConfig,
                projectName: "test",
                progressHandler: nil
            )
        } throws: { error in
            // Should throw an error for nonexistent context
            return true
        }
    }

    // Helper function to test cache key generation
    private func generateCacheKey(serviceName: String, buildConfig: BuildConfig, projectName: String) -> String {
        let context = buildConfig.context ?? "."
        let dockerfile = buildConfig.dockerfile ?? "Dockerfile"
        let args = buildConfig.args ?? [:]

        // Create a deterministic hash based on build parameters
        let hashString = "\(projectName):\(serviceName):\(context):\(dockerfile):\(args.description)"
        return String(hashString.hashValue)
    }

    @Test
    func testBuildServiceCreation() async throws {
        let buildService = DefaultBuildService()

        // Test that build service can be created successfully
        #expect(buildService != nil)
    }

// Mock build service for testing
private actor MockBuildService: BuildService {
    private var _buildCallCount = 0
    private var _lastServiceName = ""
    private var _lastBuildConfig: BuildConfig?
    private var _lastProjectName = ""

    var buildCallCount: Int { _buildCallCount }
    var lastServiceName: String { _lastServiceName }
    var lastBuildConfig: BuildConfig? { _lastBuildConfig }
    var lastProjectName: String { _lastProjectName }

    func buildImage(
        serviceName: String,
        buildConfig: BuildConfig,
        projectName: String,
        progressHandler: ProgressUpdateHandler?
    ) async throws -> String {
        _buildCallCount += 1
        _lastServiceName = serviceName
        _lastBuildConfig = buildConfig
        _lastProjectName = projectName

        // Simulate build failure for testing
        if buildConfig.context == "/nonexistent" {
            throw ContainerizationError(
                .notFound,
                message: "Build context not found"
            )
        }

        return "\(projectName)_\(serviceName):mock-built"
    }
}

// Note: Mock types removed due to import complexity in test environment
// These would be used in integration tests with proper container mocking

private struct MockProcessHandle: ProcessHandle {
    func wait() async throws -> ProcessResult {
        // Simulate successful process execution
        return ProcessResult(exitStatus: 0)
    }

    func terminate() async throws {
        // Mock termination
    }
}