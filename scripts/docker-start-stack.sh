#!/usr/bin/env bash
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$INFRA_DIR/.." && pwd)"
WEBSITE_DIR="${WEBSITE_DIR:-$ROOT_DIR/MagicTheGatheringWebsite}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$ROOT_DIR/MagicTheGatheringAccounts}"
COMMERCE_DIR="${COMMERCE_DIR:-$ROOT_DIR/MagicTheGatheringCommerce}"

RESET_VOLUMES=false
NO_CACHE=false
SEED_DATABASE=false

usage() {
    cat <<EOF
Usage: ./scripts/docker-start-stack.sh [options]

Builds and starts the full stack with Docker only. The backend jars are built
inside Docker images, so no local JDK or local Maven install is required.

Options:
  --reset-volumes     Run docker compose down -v before starting
  --keep-volumes      Keep existing Docker volumes. This is the default
  --no-cache          Rebuild Docker images without cache
  --seed              Run website MagicDataRetriever/databaseIntake.py after startup
  -h, --help          Show this help

Environment:
  WEBSITE_DIR         Default: ../MagicTheGatheringWebsite
  ACCOUNTS_DIR        Default: ../MagicTheGatheringAccounts
  COMMERCE_DIR        Default: ../MagicTheGatheringCommerce
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-volumes)
            RESET_VOLUMES=true
            ;;
        --keep-volumes)
            RESET_VOLUMES=false
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --seed)
            SEED_DATABASE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [[ -f "$INFRA_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$INFRA_DIR/.env"
    set +a
fi

required_env_vars=(
    POSTGRES_DB
    POSTGRES_USER
    POSTGRES_PASSWORD
    KC_DB_USERNAME
    KC_DB_PASSWORD
    SPRING_R2DBC_USERNAME
    SPRING_R2DBC_PASSWORD
    ACCOUNTS_FLYWAY_URL
    WEBSITE_R2DBC_URL
    WEBSITE_FLYWAY_URL
    COMMERCE_R2DBC_URL
    COMMERCE_FLYWAY_URL
    KEYCLOAK_ADMIN
    KEYCLOAK_ADMIN_PASSWORD
    KEYCLOAK_ADMIN_USERNAME
    KEYCLOAK_INTERNAL_URL
    KEYCLOAK_ISSUER_URL
    KEYCLOAK_JWK_SET_URI
)

for env_var in "${required_env_vars[@]}"; do
    if [[ -z "${!env_var:-}" ]]; then
        echo "Missing required environment variable: $env_var"
        echo "Create $INFRA_DIR/.env from $INFRA_DIR/.env.example and fill in local values."
        exit 1
    fi
done

require_repo() {
    local repo_dir="$1"
    local repo_name="$2"

    if [[ ! -d "$repo_dir" ]]; then
        echo "$repo_name repo not found: $repo_dir"
        exit 1
    fi

    if [[ ! -f "$repo_dir/pom.xml" ]]; then
        echo "$repo_name repo does not contain pom.xml: $repo_dir"
        exit 1
    fi

    if [[ ! -f "$repo_dir/Dockerfile" ]]; then
        echo "$repo_name repo does not contain Dockerfile: $repo_dir"
        exit 1
    fi
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker is required, but docker is not on PATH."
        echo "Install and start Docker Desktop, then rerun this script."
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "Docker Compose is required, but 'docker compose' is not available."
        echo "Install a current Docker Desktop version, then rerun this script."
        exit 1
    fi
}

wait_for_postgres() {
    echo "Waiting for Postgres to accept connections..."
    local attempts=0

    until (cd "$INFRA_DIR" && docker compose exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}") >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [[ "$attempts" -gt 60 ]]; then
            echo "Postgres did not become ready in time."
            exit 1
        fi
        sleep 2
    done
}

ensure_database() {
    local database_name="$1"
    local database_exists

    if [[ ! "$database_name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "Refusing unsafe database name: $database_name"
        exit 1
    fi

    echo "Ensuring database exists: $database_name"
    database_exists="$(cd "$INFRA_DIR" && docker compose exec -T postgres psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        -tAc "SELECT 1 FROM pg_database WHERE datname = '$database_name'")"

    if [[ "$database_exists" == "1" ]]; then
        echo "Database already exists: $database_name"
        return
    fi

    (cd "$INFRA_DIR" && docker compose exec -T postgres psql \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        -c "CREATE DATABASE \"$database_name\"")
}

seed_database() {
    local seed_script="$WEBSITE_DIR/MagicDataRetriever/databaseIntake.py"
    local seed_dir
    local seed_python

    if [[ ! -f "$seed_script" ]]; then
        echo "Seed requested, but no seed script was found at: $seed_script"
        echo "Skipping seed step."
        return
    fi

    seed_dir="$(dirname "$seed_script")"
    if [[ -x "$seed_dir/.venv/Scripts/python.exe" ]]; then
        seed_python="$seed_dir/.venv/Scripts/python.exe"
    elif [[ -x "$seed_dir/.venv/bin/python" ]]; then
        seed_python="$seed_dir/.venv/bin/python"
    elif command -v python3 >/dev/null 2>&1; then
        seed_python="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
        seed_python="$(command -v python)"
    else
        echo "Seed requested, but no Python interpreter was found."
        echo "Create a venv in $seed_dir with: python -m venv .venv"
        exit 1
    fi

    echo "Seeding website card and store inventory data..."
    echo "Using Python: $seed_python"
    (cd "$seed_dir" && "$seed_python" databaseIntake.py)
}

require_repo "$WEBSITE_DIR" "website"
require_repo "$ACCOUNTS_DIR" "accounts"
require_repo "$COMMERCE_DIR" "commerce"
require_docker

if [[ "$RESET_VOLUMES" == true ]]; then
    echo "Stopping stack and removing volumes..."
    (cd "$INFRA_DIR" && docker compose down -v)
else
    echo "Stopping stack and keeping volumes..."
    (cd "$INFRA_DIR" && docker compose down)
fi

echo "Starting Postgres and Redis..."
(cd "$INFRA_DIR" && docker compose up -d postgres redis)
wait_for_postgres
ensure_database "account_db"
ensure_database "marketplace_db"
ensure_database "keycloak_db"
ensure_database "commerce_db"

if [[ "$NO_CACHE" == true ]]; then
    echo "Building Docker images without cache..."
    (cd "$INFRA_DIR" && docker compose build --no-cache)
    echo "Starting full stack..."
    (cd "$INFRA_DIR" && docker compose up -d)
else
    echo "Building and starting full stack..."
    (cd "$INFRA_DIR" && docker compose up -d --build)
fi

if [[ "$SEED_DATABASE" == true ]]; then
    seed_database
fi

echo "Done."
echo "Keycloak:     http://localhost:8081"
echo "Accounts API: http://localhost:8082"
echo "Website API:  http://localhost:8083"
echo "Commerce API: http://localhost:8084"
