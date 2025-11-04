#!/bin/bash
set -euo pipefail

# Database startup and schema apply script for PostgreSQL
# - Waits for server readiness
# - Creates role/user and database if needed
# - Applies schema.sql idempotently (no drops)
# - Writes connection info to db_visualizer/postgres.env
# - Uses env variables if present, otherwise falls back to defaults

# Config with environment overrides
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5000}"
# superuser to run management commands (default 'postgres' unix user)
PG_SUPERUSER_UNIX="${PG_SUPERUSER_UNIX:-postgres}"

echo "Starting PostgreSQL setup for database '${DB_NAME}' on ${DB_HOST}:${DB_PORT} ..."

# Locate PostgreSQL binaries
if [ -z "${PG_BIN:-}" ] || [ ! -d "${PG_BIN:-}" ]; then
  PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1 || true)
  if [ -n "${PG_VERSION}" ]; then
    PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
  else
    # Fallback: try common PATH usage
    PG_BIN=""
  fi
fi

# Helper: run a postgres binary (preferring absolute path if discovered)
pg_bin() {
  local cmd="$1"
  if [ -n "${PG_BIN}" ] && [ -x "${PG_BIN}/${cmd}" ]; then
    echo "${PG_BIN}/${cmd}"
  else
    # rely on PATH
    echo "${cmd}"
  fi
}

# Check if Postgres is already accepting connections
is_ready() {
  sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin pg_isready)" -h "${DB_HOST}" -p "${DB_PORT}" > /dev/null 2>&1
}

# Ensure cluster data dir exists (best effort; skip if managed externally like Docker official image)
ensure_initdb() {
  # Only attempt if typical Debian/Ubuntu layout present and not initialized
  if [ -n "${PG_BIN}" ] && [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL data directory (first run)..."
    sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin initdb)" -D /var/lib/postgresql/data >/dev/null
  fi
}

# Start server if not already running (best effort)
start_server_if_needed() {
  if is_ready; then
    echo "PostgreSQL already accepting connections on ${DB_HOST}:${DB_PORT}."
    return
  fi

  # Try to detect running process on the same port regardless of readiness
  if pgrep -f "postgres.*-p ${DB_PORT}" >/dev/null 2>&1; then
    echo "Detected a running postgres process on port ${DB_PORT}; waiting for readiness..."
  else
    # Attempt to start using common invocation if cluster is local
    if [ -n "${PG_BIN}" ] && [ -d "/var/lib/postgresql/data" ]; then
      echo "Starting PostgreSQL server locally..."
      sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin postgres)" -D /var/lib/postgresql/data -p "${DB_PORT}" >/tmp/postgres-startup.log 2>&1 &
      sleep 1
    else
      echo "PostgreSQL not started by this script (likely managed externally)."
    fi
  fi
}

# Wait for readiness
wait_for_ready() {
  echo "Waiting for PostgreSQL readiness on ${DB_HOST}:${DB_PORT} ..."
  for i in $(seq 1 60); do
    if is_ready; then
      echo "PostgreSQL is ready (attempt ${i})."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: PostgreSQL did not become ready on ${DB_HOST}:${DB_PORT} within timeout." >&2
  exit 1
}

# Idempotent role creation and password set
create_or_update_role() {
  sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin psql)" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SQL
}

# Idempotent database creation
create_db_if_needed() {
  sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin psql)" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') THEN
    PERFORM d.datname FROM pg_database d WHERE d.datname = '${DB_NAME}';
    IF NOT FOUND THEN
      EXECUTE format('CREATE DATABASE %I', '${DB_NAME}');
    END IF;
  END IF;
END
\$\$;
SQL
}

# Schema and privileges setup
apply_privileges() {
  sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin psql)" -h "${DB_HOST}" -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 <<SQL
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
SQL

  # Schema-level permissions inside target database
  sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin psql)" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 <<SQL
-- Allow usage and create on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Default privileges for future objects
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- Ensure user has access to existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
SQL
}

# Apply schema.sql (idempotent; fail on errors)
apply_schema() {
  local schema_path="$(dirname "$0")/schema.sql"
  if [ ! -f "${schema_path}" ]; then
    echo "Schema file not found at ${schema_path}; skipping schema application."
    return 0
  fi

  echo "Applying schema from ${schema_path} to ${DB_NAME} ..."
  # Use ON_ERROR_STOP to exit on errors as required
  if ! sudo -u "${PG_SUPERUSER_UNIX}" "$(pg_bin psql)" -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${schema_path}"; then
    echo "ERROR: Applying schema failed." >&2
    exit 2
  fi
  echo "Schema applied successfully."
}

# Write helper files
write_connection_files() {
  local conn_str="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  echo "psql ${conn_str}" > "$(dirname "$0")/db_connection.txt"
  echo "Connection string saved to db_connection.txt"

  cat > "$(dirname "$0")/db_visualizer/postgres.env" <<EOF
export POSTGRES_URL="postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF
  echo "Environment variables saved to db_visualizer/postgres.env"
  echo "To use with Node.js viewer: source db_visualizer/postgres.env"
}

# Main flow
ensure_initdb
start_server_if_needed
wait_for_ready
create_or_update_role
create_db_if_needed
apply_privileges
apply_schema
write_connection_files

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Host: ${DB_HOST}"
echo "Port: ${DB_PORT}"
echo "To connect: psql -h ${DB_HOST} -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
