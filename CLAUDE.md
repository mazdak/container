## Container Compose Plugin

The Container Compose feature is now implemented as a plugin following the Apple Container plugin architecture.

### Plugin Structure

  Plugins/container-compose/
  ├── Package.swift                     # Independent Swift package
  ├── config.json                       # Plugin metadata
  ├── README.md                         # Plugin documentation
  ├── Sources/
  │   ├── CLI/                          # Command implementations
  │   │   ├── main.swift                # Plugin entry point
  │   │   ├── ComposeUp.swift           # Up subcommand
  │   │   ├── ComposeDown.swift         # Down subcommand
  │   │   ├── ComposePS.swift           # PS subcommand
  │   │   ├── ComposeLogs.swift         # Logs subcommand
  │   │   ├── ComposeExec.swift         # Exec subcommand
  │   │   ├── ComposeStart.swift        # Start subcommand
  │   │   ├── ComposeStop.swift         # Stop subcommand
  │   │   └── ComposeValidate.swift     # Validate subcommand
  │   └── Core/                         # Core compose library
  │       ├── Parser/
  │       │   ├── ComposeFile.swift     # YAML structures
  │       │   ├── ComposeParser.swift   # YAML parsing logic
  │       │   └── ComposeFileMerger.swift # File merging logic
  │       ├── Orchestrator/
  │       │   ├── Orchestrator.swift    # Main orchestration logic
  │       │   ├── DependencyResolver.swift # Topological sorting
  │       │   └── ProjectConverter.swift # Convert compose to project
  │       └── Models/
  │           ├── Project.swift         # Project representation
  │           └── ComposeFile.swift     # Compose file models
  └── Tests/
      ├── ComposeTests/                 # Unit tests
      └── CLITests/                     # Integration tests

### Building the Plugin

From the main project root:
```bash
# Build everything including plugins
make all

# Build only the compose plugin
make plugin-compose

# Install everything (includes plugin)
make install
```

From the plugin directory:
```bash
cd Plugins/container-compose
swift build
swift test
```

### Plugin Development Guidelines

1. **Independence**: The plugin has its own Package.swift and can be developed independently
2. **Integration**: Uses the main container's libraries (ContainerClient, ContainerLog, etc.)
3. **Testing**: Has its own test suite that can be run independently
4. **Installation**: Automatically installed to `/usr/local/libexec/container/plugins/container-compose/`

### Swift Coding Conventions for Plugins

- **Entry Point**: Use `@main` struct conforming to `AsyncParsableCommand`
- **Commands**: Standalone structs (not in `extension Application`)
- **Imports**: Use `ComposeCore` for internal functionality
- **Error Handling**: Use ContainerizationError with proper error codes
- **Progress**: Use ProgressBar with ProgressConfig for operations
- **Async/Await**: All commands use AsyncParsableCommand
- **Flags**: Define local Flags struct for common options
- **Logging: Create global logger with appropriate label
- **File Headers**: Include Apache 2.0 license header

## Container Compose Documentation

When documenting the Container Compose feature:
1. **User Documentation**: The COMPOSE.md file is located in the plugin directory
2. **Feature Documentation**: Explain all supported docker-compose features
3. **Limitations Documentation**: Clearly list unsupported features with one-line explanations
4. **Examples**: Provide practical examples for common use cases
5. **Migration Guide**: Include guidance for migrating from Docker Compose
6. **No Emojis**: Avoid using emojis in documentation unless explicitly requested

### Health Check Implementation

The compose feature includes basic health check support:
- **Parsing**: Full support for docker-compose healthcheck syntax
- **Execution**: Health checks are executed using container.createProcess()
- **Status Tracking**: Health status shown in `compose ps` output
- **Manual Checks**: `compose health` command for on-demand health checking
- **Initial Check**: Health checks run after container start with start_period delay
- **Limitations**: No continuous monitoring or automatic restart on failure

## Testing Framework

The Apple Container project uses **Swift Testing** framework throughout the codebase, not XCTest.

### Swift Testing Patterns

1. **Framework**: Use `import Testing` (not `import XCTest`)
2. **Test Structure**: Use structs (not classes inheriting from XCTestCase)
3. **Test Attributes**: Use `@Test` attribute before test functions
4. **Assertions**: Use `#expect()` instead of XCTAssert
5. **Error Testing**: Use `#expect { } throws: { error in }` pattern
6. **Parameterized Tests**: Use `@Test(arguments:)` for data-driven tests

### Example Test Structure

```swift
import Testing
import Foundation
@testable import ModuleName

struct MyTests {
    @Test
    func testBasicFunctionality() throws {
        let result = performOperation()
        #expect(result == expectedValue)
    }
    
    @Test
    func testErrorHandling() throws {
        #expect {
            try performFailingOperation()
        } throws: { error in
            guard let containerError = error as? ContainerizationError else {
                return false
            }
            return containerError.code == .expectedCode
        }
    }
    
    @Test(arguments: [1, 2, 3, 4, 5])
    func testWithParameters(value: Int) throws {
        let result = compute(value)
        #expect(result > 0)
    }
}
```

### Test Organization

1. **Unit Tests**: Located in `Tests/{Module}Tests/`
2. **CLI Tests**: Located in `Tests/CLITests/Subcommands/{Feature}/`
3. **Plugin Tests**: Each plugin has its own `Tests/` directory
4. **Test Helpers**: Use base classes like `CLITest` for common functionality

### CLI Test Patterns

```swift
struct TestCLICommand: CLITest {
    @Test
    func testCommand() throws {
        // Setup
        let name = Test.current?.name.trimmingCharacters(in: ["(", ")"])
        defer { cleanup() }
        
        // Run container
        try doLongRun(name: name, args: [])
        
        // Execute and verify
        let output = try doExec(name: name, cmd: ["command"])
        #expect(output.contains("expected"))
    }
}
```

### Best Practices

1. **Descriptive Names**: Use clear, descriptive test function names
2. **Test Isolation**: Each test should be independent
3. **Resource Cleanup**: Use `defer` blocks for cleanup
4. **Async Tests**: Use `async` test methods for async code
5. **Mock Logger**: Create Logger instances with label "test"
6. **Test Coverage**: Write tests for both success and failure cases
