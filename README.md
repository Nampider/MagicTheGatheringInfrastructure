# MagicTheGatheringInfrastructure
This repo contains the infrastructure information for the Magic The Gathering Website. Including but not limited to Docker Compose Files

## Prerequisites

Install these before running the local stack:

- Docker Desktop
- Git Bash or another Bash-compatible shell

The Docker-only command below does not require a local JDK or local Maven install.

The older restart automation script still builds jars on the host machine. If you use
`./scripts/restart-stack.sh`, install JDK 21 and make sure `java -version` and
`javac -version` both work from the same terminal.

## Docker-Only Start

From this infrastructure repo, run:

```bash
./scripts/docker-start-stack.sh
```

This builds the backend jars inside Docker images, creates any missing Postgres
databases, and starts the full stack.

Common commands:

```bash
./scripts/docker-start-stack.sh
./scripts/docker-start-stack.sh --reset-volumes
./scripts/docker-start-stack.sh --no-cache
./scripts/docker-start-stack.sh --seed
```

Use `--reset-volumes` when you want a clean Postgres/Keycloak volume. Use `--seed`
when you want to run the website card data intake after startup; that seed step
still requires Python locally.

## Local Restart Automation

This script is useful for faster local rebuilds when you already have JDK 21 installed.

From this infrastructure repo, run:

```bash
./scripts/restart-stack.sh --seed
```

The script checks the sibling app repos:

- `../MagicTheGatheringWebsite`
- `../MagicTheGatheringAccounts`
- `../MagicTheGatheringCommerce`

When any repo changed, it packages the service with its Maven wrapper when present, rebuilds that service's Docker image, optionally pushes the changed image, and then restarts Docker Compose.

Common commands:

```bash
./scripts/restart-stack.sh --seed
./scripts/restart-stack.sh --push --seed
./scripts/restart-stack.sh --push --seed --no-cache
./scripts/restart-stack.sh --keep-volumes
./scripts/restart-stack.sh --force --push --seed
```

By default the restart uses:

```bash
docker compose down -v
docker compose up -d
```

Use `--keep-volumes` when you do not want to delete Postgres data.
