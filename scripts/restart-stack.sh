#!/usr/bin/env bash
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$INFRA_DIR/.." && pwd)"
WEBSITE_DIR="${WEBSITE_DIR:-$ROOT_DIR/magicthegatheringwebsite}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-$ROOT_DIR/magicthegatheringaccounts}"
COMMERCE_DIR="${COMMERCE_DIR:-$ROOT_DIR/MagicTheGatheringCommerce}"
STATE_DIR="$INFRA_DIR/.deploy-state"

WEBSITE_IMAGE="${WEBSITE_IMAGE:-kriznn/magicthegatheringwebsite:latest}"
ACCOUNTS_IMAGE="${ACCOUNTS_IMAGE:-kriznn/magicthegatheringaccounts:latest}"
COMMERCE_IMAGE="${COMMERCE_IMAGE:-kriznn/magicthegatheringcommerce:latest}"

PUSH_IMAGES=false
NO_CACHE=false
RESET_VOLUMES=true
SEED_DATABASE=false
FORCE_BUILD=false

usage() {
    cat <<EOF
Usage: ./scripts/restart-stack.sh [options]

Checks the accounts, website, and commerce repos for changes, packages changed services,
builds their Docker images, optionally pushes them, and restarts Docker Compose.

Options:
  --push              Push changed images after building. Default: false
  --no-cache          Build changed Docker images with --no-cache. Default: false
  --keep-volumes      Use docker compose down without -v. Default removes volumes
  --seed              Run website MagicDataRetriever/databaseIntake.py after startup
  --force             Rebuild both services even if no changes are detected
  -h, --help          Show this help

Environment:
  WEBSITE_DIR         Default: ../magicthegatheringwebsite
  ACCOUNTS_DIR        Default: ../magicthegatheringaccounts
  COMMERCE_DIR        Default: ../MagicTheGatheringCommerce
  WEBSITE_IMAGE       Default: kriznn/magicthegatheringwebsite:latest
  ACCOUNTS_IMAGE      Default: kriznn/magicthegatheringaccounts:latest
  COMMERCE_IMAGE      Default: kriznn/magicthegatheringcommerce:latest
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)
            PUSH_IMAGES=true
            ;;
        --no-cache)
            NO_CACHE=true
            ;;
        --keep-volumes)
            RESET_VOLUMES=false
            ;;
        --seed)
            SEED_DATABASE=true
            ;;
        --force)
            FORCE_BUILD=true
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

repo_hash() {
    local repo_dir="$1"

    (
        cd "$repo_dir"
        {
            find src -type f 2>/dev/null | sort
            if [[ -d MagicDataRetriever ]]; then
                find MagicDataRetriever -maxdepth 1 -type f | sort
            fi
            printf '%s\n' pom.xml Dockerfile
        } | while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                shasum -a 256 "$file"
            fi
        done
    ) | shasum -a 256 | awk '{print $1}'
}

build_service_if_changed() {
    local service_name="$1"
    local repo_dir="$2"
    local image_name="$3"
    local state_file="$STATE_DIR/$service_name.sha256"

    local new_hash
    local old_hash=""

    new_hash="$(repo_hash "$repo_dir")"

    if [[ -f "$state_file" ]]; then
        old_hash="$(cat "$state_file")"
    fi

    if [[ "$FORCE_BUILD" == true || "$new_hash" != "$old_hash" ]]; then
        echo "$service_name changes detected. Packaging and building $image_name..."

        (cd "$repo_dir" && mvn -DskipTests package)

        local docker_build_args=(-t "$image_name")
        if [[ "$NO_CACHE" == true ]]; then
            docker_build_args=(--no-cache "${docker_build_args[@]}")
        fi

        (cd "$repo_dir" && docker build "${docker_build_args[@]}" .)

        if [[ "$PUSH_IMAGES" == true ]]; then
            docker push "$image_name"
        fi

        printf '%s' "$new_hash" > "$state_file"
    else
        echo "No $service_name changes detected. Skipping Maven and Docker build."
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

require_repo "$WEBSITE_DIR" "website"
require_repo "$ACCOUNTS_DIR" "accounts"
require_repo "$COMMERCE_DIR" "commerce"
mkdir -p "$STATE_DIR"

build_service_if_changed "website" "$WEBSITE_DIR" "$WEBSITE_IMAGE"
build_service_if_changed "accounts" "$ACCOUNTS_DIR" "$ACCOUNTS_IMAGE"
build_service_if_changed "commerce" "$COMMERCE_DIR" "$COMMERCE_IMAGE"

echo "Restarting Docker Compose stack from $INFRA_DIR..."

if [[ "$RESET_VOLUMES" == true ]]; then
    (cd "$INFRA_DIR" && docker compose down -v)
else
    (cd "$INFRA_DIR" && docker compose down)
fi

(cd "$INFRA_DIR" && docker compose up -d postgres)
wait_for_postgres
ensure_database "account_db"
ensure_database "marketplace_db"
ensure_database "keycloak_db"
ensure_database "commerce_db"

(cd "$INFRA_DIR" && docker compose up -d)

if [[ "$SEED_DATABASE" == true ]]; then
    echo "Seeding website card and store inventory data..."
    (cd "$WEBSITE_DIR/MagicDataRetriever" && python3 databaseIntake.py)
fi

echo "Done."
echo "Website API: http://localhost:8083"
echo "Accounts API: http://localhost:8082"
echo "Commerce API: http://localhost:8084"
