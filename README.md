# MagicTheGatheringInfrastructure
This repo contains the infrastructure information for the Magic The Gathering Website. Including but not limited to Docker Compose Files

## Local Restart Automation

From this infrastructure repo, run:

```bash
./scripts/restart-stack.sh --seed
```

The script checks both sibling app repos:

- `../magicthegatheringwebsite`
- `../magicthegatheringaccounts`

When either repo changed, it runs `mvn -DskipTests package`, rebuilds that service's Docker image, optionally pushes the changed image, and then restarts Docker Compose.

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
