# Container Compose

Apple Container's implementation of docker-compose functionality, allowing you to define and run multi-container applications using familiar docker-compose YAML syntax.

## Overview

Container Compose brings the convenience of docker-compose to Apple Container, enabling you to:
- Define multi-container applications in a single YAML file
- Manage service dependencies automatically
- Start, stop, and manage entire application stacks with simple commands
- Use environment variable interpolation for flexible configurations

## Quick Start

1. Create a `docker-compose.yml` file:

```yaml
version: '3'
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    depends_on:
      - api
  
  api:
    image: node:alpine
    environment:
      DATABASE_URL: postgres://db:5432/myapp
    depends_on:
      - db
  
  db:
    image: postgres:alpine
    environment:
      POSTGRES_DB: myapp
      POSTGRES_PASSWORD: secret
```

2. Start your application:

```bash
container compose up -d
```

3. View running services:

```bash
container compose ps
```

4. Stop and remove everything:

```bash
container compose down
```

## Commands

### `compose up`
Start all services defined in the compose file.

```bash
container compose up [options] [SERVICE...]
```

Options:
- `-d, --detach`: Run containers in the background
- `--force-recreate`: Recreate containers even if configuration unchanged
- `--no-recreate`: Don't recreate existing containers
- `--profile <name>`: Activate profiles (can be specified multiple times)

### `compose down`
Stop and remove containers, networks, and volumes.

```bash
container compose down [options]
```

Options:
- `-v, --volumes`: Remove named volumes (currently not implemented)

### `compose ps`
List containers for a compose project.

```bash
container compose ps
```

### `compose start`
Start existing containers for a service.

```bash
container compose start [SERVICE...]
```

### `compose stop`
Stop running containers without removing them.

```bash
container compose stop [options] [SERVICE...]
```

Options:
- `-t, --timeout <seconds>`: Timeout in seconds (default: 10)

### `compose restart`
Restart containers.

```bash
container compose restart [options] [SERVICE...]
```

Options:
- `-t, --timeout <seconds>`: Timeout in seconds (default: 10)

### `compose logs`
View output from containers.

```bash
container compose logs [options] [SERVICE...]
```

Options:
- `-f, --follow`: Follow log output
- `--tail <number>`: Number of lines to show from the end
- `-t, --timestamps`: Show timestamps

### `compose exec`
Execute a command in a running container.

```bash
container compose exec [options] SERVICE COMMAND [ARG...]
```

Options:
- `-d, --detach`: Detached mode
- `-i, --interactive`: Keep STDIN open
- `-t, --tty`: Allocate a pseudo-TTY
- `-u, --user <user>`: Run as specified username or UID
- `-w, --workdir <dir>`: Working directory inside the container

### `compose health`
Check health status of services.

```bash
container compose health [options] [SERVICE...]
```

Options:
- `-q, --quiet`: Exit with non-zero status if any service is unhealthy

### `compose validate`
Check and validate the compose file.

```bash
container compose validate
```

## Global Options

All compose commands support these global options:

- `-f, --file <path>`: Specify compose file(s) (can be used multiple times)
- `-p, --project-name <name>`: Specify project name (default: directory name)
- `--profile <name>`: Specify a profile to enable (can be used multiple times)
- `--env <KEY=VALUE>`: Set environment variables (can be used multiple times)

### Multiple Compose Files

You can specify multiple compose files using the `-f` flag. Files are merged in order, with later files overriding values from earlier files:

```bash
# Use base config and override with development settings
container compose -f docker-compose.yml -f docker-compose.dev.yml up

# Use multiple override files
container compose -f compose.yml -f compose.override.yml -f compose.local.yml up
```

When multiple files are specified:
- Services are merged by name
- Later files override scalar values (image, command, etc.)
- Environment variables are merged, with later files overriding earlier ones
- Arrays (ports, volumes) are completely replaced, not appended
- Networks and volumes are merged by name

Example of file merging:

**docker-compose.yml:**
```yaml
services:
  web:
    image: myapp:latest
    environment:
      LOG_LEVEL: info
      APP_ENV: production
    ports:
      - "8080:8080"
```

**docker-compose.dev.yml:**
```yaml
services:
  web:
    environment:
      LOG_LEVEL: debug
      DEBUG: "true"
    ports:
      - "3000:8080"
    volumes:
      - ./src:/app/src
```

Result after merging:
- Image: `myapp:latest` (from base)
- Environment: `LOG_LEVEL=debug`, `APP_ENV=production`, `DEBUG=true` (merged)
- Ports: `3000:8080` (override replaces)
- Volumes: `./src:/app/src` (added from override)

## Supported Features

### Services
- Image specification
- Container naming
- Command and entrypoint override
- Working directory
- Environment variables (map or list format)
- Port mapping
- Volume mounts (bind and tmpfs)
- Network configuration
- Service dependencies
- Resource limits (CPU and memory)
- Restart policies
- Health checks (basic support - one-time checks, no continuous monitoring)
- Labels
- Profiles

### Environment Variables
- Variable interpolation with `${VAR}` syntax
- Default values with `${VAR:-default}`
- Environment files with `env_file`

### Volumes
- Named volumes: `volume_name:/container/path`
- Bind mounts: `/host/path:/container/path`
- Read-only mounts: `/host/path:/container/path:ro` or `volume_name:/container/path:ro`
- Tmpfs mounts: `type: tmpfs`

Named volumes are automatically created in `~/.container/volumes/` and persist across container lifecycles.

### Networks
- Basic network support (macOS 26+ required for non-default networks)
- Default network created automatically

### Profiles
- Service profiles for selective deployment
- Activate with `--profile` flag

## Limitations

### Not Supported
1. **Build** - Cannot build images from Dockerfile (Apple Container is a runtime, not a build system)
2. **Secrets and Configs** - Not implemented (requires additional infrastructure not present)
3. **Deploy/Swarm features** - Not applicable (Apple Container is a single-host runtime)
4. **Volume drivers** - Only local driver supported (no nfs, cifs, etc.)
5. **Container name resolution** - Services cannot resolve each other by name (no embedded DNS server)
6. **Scale** - No support for scaling services (requires service management beyond container lifecycle)
7. **External networks/volumes** - Not implemented (implies pre-existing infrastructure)
8. **Health check monitoring** - Basic support only (executes checks but no continuous monitoring or restart on failure)
9. **Long syntax for ports/volumes** - Only short syntax supported in some cases

### Differences from Docker Compose
1. **Networking** - Containers use bridge networking but without automatic DNS
2. **Volume permissions** - May have different permission semantics
3. **Image format** - Uses OCI images
4. **Platform** - macOS specific features and limitations

### Workarounds
- For inter-container communication, use the gateway IP (typically 192.168.64.1)
- For databases, consider using tmpfs volumes to avoid permission issues
- Pre-pull images as build is not supported

## Examples

### Web Application with Database

```yaml
version: '3'
services:
  web:
    image: nginx:alpine
    ports:
      - "80:80"
    volumes:
      - ./html:/usr/share/nginx/html:ro
    depends_on:
      - api

  api:
    image: node:alpine
    ports:
      - "3000:3000"
    environment:
      DATABASE_HOST: 192.168.64.1  # Use gateway IP
      DATABASE_PORT: 5432
    depends_on:
      - postgres

  postgres:
    image: postgres:alpine
    ports:
      - "5432:5432"
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password
    volumes:
      - pgdata:/var/lib/postgresql/data  # Named volume for persistent data

volumes:
  pgdata:  # Declares the named volume
```

### Using Profiles

```yaml
version: '3.9'
services:
  app:
    image: myapp:latest
    
  debug:
    image: busybox
    profiles: ["debug"]
    command: ["sleep", "infinity"]
    
  test:
    image: myapp:test
    profiles: ["test"]
    command: ["npm", "test"]
```

Run with profiles:
```bash
# Normal mode - only 'app' starts
container compose up

# Debug mode - 'app' and 'debug' start
container compose --profile debug up

# Test mode - 'app' and 'test' start  
container compose --profile test up
```

### Environment Variables

```yaml
version: '3'
services:
  web:
    image: ${WEB_IMAGE:-nginx:alpine}
    environment:
      - API_URL=http://${API_HOST:-localhost}:${API_PORT:-3000}
    env_file:
      - .env
      - web.env
```

## Troubleshooting

### Common Issues

1. **"Image not found"** - Pre-pull images with `container images pull <image>`
2. **"Port already in use"** - Check for conflicts with `lsof -i :<port>`
3. **"Service depends on unknown service"** - Check service names and YAML indentation
4. **Container can't connect to another container** - Use gateway IP instead of service names

### Debug Commands

```bash
# Validate compose file
container compose validate

# View detailed container info
container inspect <container-name>

# Check container logs
container compose logs <service-name>

# Execute debug commands
container compose exec <service> /bin/sh
```

## Best Practices

1. **Use specific image tags** instead of `latest` for reproducibility
2. **Set resource limits** to prevent containers from consuming too much CPU/memory
3. **Use environment files** for sensitive configuration
4. **Leverage profiles** for different environments (dev, test, prod)
5. **Always validate** your compose file before deployment
6. **Use tmpfs** for temporary data that doesn't need persistence

## Migration from Docker Compose

When migrating from Docker Compose:

1. **Remove build sections** - Pre-build images separately
2. **Update network references** - Use IP addresses instead of service names
3. **Adjust volume paths** - Ensure paths exist and have proper permissions
4. **Remove unsupported options** - Scale, external resources, etc.
5. **Test thoroughly** - Behavior may differ in subtle ways

## Volume Management

Apple Container now supports named volumes that persist data across container lifecycles. Volumes are stored in `~/.container/volumes/`.

### Volume Commands

```bash
# Create a volume
container volume create mydata

# List volumes
container volume ls

# Inspect a volume
container volume inspect mydata

# Remove a volume
container volume rm mydata

# Remove multiple volumes
container volume rm vol1 vol2 vol3
```

### Using Volumes with Compose

```yaml
version: '3'
services:
  app:
    image: myapp:latest
    volumes:
      - appdata:/var/lib/app     # Named volume
      - ./config:/etc/app:ro     # Bind mount (read-only)
      - cache:/tmp/cache         # Another named volume

volumes:
  appdata:    # Automatically created if doesn't exist
  cache:
```

### Volume Persistence

Named volumes persist even after `compose down`. To remove volumes when stopping:

```bash
# Note: -v flag for volume removal is not yet implemented
# Use container volume rm <volume_name> to manually remove volumes
```

## Contributing

Container Compose is part of the Apple Container project. To contribute:

1. Check existing issues and discussions
2. Follow the project's coding standards
3. Add tests for new functionality
4. Update documentation as needed

For more information, see the main project documentation.