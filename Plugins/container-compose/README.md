# Container Compose Plugin

This plugin provides docker-compose functionality for Apple Container, allowing you to define and run multi-container applications using familiar docker-compose YAML syntax.

## Features

- **Service Orchestration**: Define and run multi-container applications
- **Build Support**: Automatically build Docker images from Dockerfiles
- **Dependency Management**: Handle service dependencies and startup order
- **Volume Management**: Support for named volumes and bind mounts
- **Network Configuration**: Automatic network setup and service discovery
- **Health Checks**: Built-in health check support
- **Environment Variables**: Flexible environment variable handling

## Building

From the plugin directory:
```bash
swift build
```

From the main project root:
```bash
make plugin-compose
```

## Installation

The plugin is automatically installed when you build and install the main container project:
```bash
make install
```

The plugin will be installed to:
```
/usr/local/libexec/container/plugins/compose/
```

## Usage

Once installed, the plugin integrates seamlessly with the container CLI:
```bash
container compose up
container compose down
container compose ps
# etc.
```

## Build Support

The plugin now supports building Docker images directly from your compose file:

```yaml
version: '3.8'
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        NODE_ENV: production
    ports:
      - "8000:8000"

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile.dev
    ports:
      - "3000:3000"
```

When you run `container compose up`, the plugin will:
1. Automatically detect services with `build:` configurations
2. Build Docker images using Apple Container's native build system
3. Start containers from the built images
4. Cache builds to avoid unnecessary rebuilds

### Build Configuration Options

- `context`: Build context directory (default: ".")
- `dockerfile`: Path to Dockerfile (default: "Dockerfile")
- `args`: Build arguments as key-value pairs

### Build Caching

The plugin implements intelligent build caching based on:
- Build context directory
- Dockerfile path and content
- Build arguments

Services with unchanged build configurations will reuse cached images.

## Documentation

See COMPOSE.md for detailed documentation on supported features and usage.

## Development

The plugin follows the standard Apple Container plugin architecture:
- `config.json` - Plugin metadata and configuration
- `Sources/CLI/` - Command-line interface implementation
- `Sources/Core/` - Core compose functionality (parser, orchestrator, etc.)
- `Tests/` - Unit and integration tests

## Testing

Run tests from the plugin directory:
```bash
swift test
```