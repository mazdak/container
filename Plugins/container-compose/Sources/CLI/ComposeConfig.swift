//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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
import ComposeCore
import Foundation
import Yams

struct ComposeConfig: AsyncParsableCommand {
    enum OutputFormat: String, ExpressibleByArgument {
        case yaml
        case json
    }

    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Parse, resolve, and render the compose file"
    )

    @OptionGroup
    var composeOptions: ComposeOptions

    @OptionGroup
    var global: ComposeGlobalOptions

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Only validate the configuration, don't print anything")
    var quiet: Bool = false

    @Flag(name: .customLong("services"), help: "Print the service names, one per line")
    var servicesOnly: Bool = false

    @Flag(name: .customLong("images"), help: "Print the image names, one per line")
    var imagesOnly: Bool = false

    @Flag(name: .customLong("networks"), help: "Print the network names, one per line")
    var networksOnly: Bool = false

    @Flag(name: .customLong("volumes"), help: "Print the volume names, one per line")
    var volumesOnly: Bool = false

    @Flag(name: .customLong("profiles"), help: "Print the profile names, one per line")
    var profilesOnly: Bool = false

    @Option(name: .customLong("format"), help: "Output format: yaml or json")
    var format: OutputFormat = .yaml

    @Argument(help: "Optional services to include in the rendered output")
    var selectedServices: [String] = []

    func run() async throws {
        global.configureLogging()
        let fileURLs = composeOptions.getComposeFileURLs()
        composeOptions.prepareEnvironment(fileURLs: fileURLs)

        let parser = ComposeParser(log: log, allowAnchors: global.allowAnchors)
        let composeFile = try parser.parse(from: fileURLs)
        composeOptions.exportDotEnvForEnvFileExpansion(fileURLs: fileURLs)
        let projectDirectory = composeOptions.getProjectDirectory(fileURLs: fileURLs)
        let projectName = composeOptions.resolveProjectName(composeFile: composeFile, fileURLs: fileURLs)
        let project = try ProjectConverter(log: log, projectDirectory: projectDirectory).convert(
            composeFile: composeFile,
            projectName: projectName,
            profiles: composeOptions.profile,
            selectedServices: selectedServices
        )

        try validateSelection(project: project)

        if quiet {
            return
        }

        let rendered = filteredComposeFile(composeFile: composeFile, serviceNames: Set(project.services.keys))

        if servicesOnly {
            printLines(rendered.services.keys.sorted())
            return
        }

        if imagesOnly {
            let images = rendered.services.values.compactMap(\.image).sorted()
            printLines(images)
            return
        }

        if networksOnly {
            printLines((rendered.networks ?? [:]).keys.sorted())
            return
        }

        if volumesOnly {
            printLines((rendered.volumes ?? [:]).keys.sorted())
            return
        }

        if profilesOnly {
            let profiles = Set(rendered.services.values.flatMap { $0.profiles ?? [] }).sorted()
            printLines(profiles)
            return
        }

        switch format {
        case .yaml:
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(rendered)
            print(yaml.trimmingCharacters(in: .whitespacesAndNewlines))
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rendered)
            guard let json = String(data: data, encoding: .utf8) else {
                throw ValidationError("Failed to encode rendered compose config as UTF-8 JSON")
            }
            print(json)
        }
    }

    internal func validateSelection(project: Project) throws {
        guard !selectedServices.isEmpty else { return }
        let missing = Set(selectedServices).subtracting(project.services.keys).sorted()
        if !missing.isEmpty {
            throw ValidationError("Services not found or not enabled by active profiles: \(missing.joined(separator: ", "))")
        }
    }

    internal func filteredComposeFile(composeFile: ComposeFile, serviceNames: Set<String>) -> ComposeFile {
        let services = composeFile.services.filter { serviceNames.contains($0.key) }
        return ComposeFile(
            version: composeFile.version,
            name: composeFile.name,
            services: services,
            networks: composeFile.networks,
            volumes: composeFile.volumes
        )
    }

    private func printLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
