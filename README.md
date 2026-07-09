# MagicTheGatheringInfrastructure
This repo contains the infrastructure information for the Magic The Gathering Website. Including but not limited to Docker Compose Files

## Local Restart Automation

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
