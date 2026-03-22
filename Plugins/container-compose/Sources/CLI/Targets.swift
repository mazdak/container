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

import ContainerAPIClient
import ContainerResource
import ComposeCore
import Foundation

/// Utilities for resolving targeted containers and computing display widths
enum TargetsUtil {
    /// Resolve targeted containers for a project/services selection, mirroring Orchestrator.logs logic
    static func resolveTargets(project: Project, services: [String]) async throws -> [(service: String, container: ContainerSnapshot)] {
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)
        let all = try await ContainerClient().list()
        return selectTargets(project: project, selected: selected, containers: all)
    }

    static func selectTargets(
        project: Project,
        services: [String],
        containers: [ContainerSnapshot]
    ) -> [(service: String, container: ContainerSnapshot)] {
        let selected = services.isEmpty ? Set(project.services.keys) : Set(services)
        return selectTargets(project: project, selected: selected, containers: containers)
    }

    static func computePrefixWidth(
        targets: [(service: String, container: ContainerSnapshot)],
        maxWidth: Int = 40
    ) -> Int {
        let maxLen = targets.map { $0.container.id.count }.max() ?? 0
        return min(maxLen, maxWidth)
    }

    private static func selectTargets(
        project: Project,
        selected: Set<String>,
        containers: [ContainerSnapshot]
    ) -> [(service: String, container: ContainerSnapshot)] {
        var targets: [(String, ContainerSnapshot)] = []
        for c in containers {
            if let proj = c.configuration.labels["com.apple.compose.project"], proj == project.name {
                let svc = c.configuration.labels["com.apple.compose.service"] ?? c.id
                if selected.contains(svc) {
                    targets.append((svc, c))
                }
                continue
            }
            let prefix = "\(project.name)_"
            if c.id.hasPrefix(prefix) {
                let svc = String(c.id.dropFirst(prefix.count))
                if selected.contains(svc) {
                    targets.append((svc, c))
                }
            }
        }
        return targets
    }

    /// Compute padding width as the longest container name among targets
    static func computePrefixWidth(project: Project, services: [String], maxWidth: Int = 40) async throws -> Int {
        let targets = try await resolveTargets(project: project, services: services)
        return computePrefixWidth(targets: targets, maxWidth: maxWidth)
    }
}
