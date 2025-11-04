# Database (PostgreSQL) — Music Streaming Service

This folder contains the PostgreSQL schema and helper scripts to initialize, apply schema, seed optional sample data, and manage backups/restores for the Music Streaming Service.

Contents:
- startup.sh — Idempotent setup script (creates role/db, applies schema.sql, writes connection helpers)
- schema.sql — Database schema for users, artists, albums, tracks, playlists, etc.
- seed.sql — Optional small sample dataset (artists/albums/tracks) for local development
- backup_db.sh / restore_db.sh — Universal backup and restore scripts (supporting SQLite/Postgres/MySQL/MongoDB backups where applicable)
- db_connection.txt — Auto-generated convenience command for psql connections
- db_visualizer/ — Simple Node.js viewer to inspect DB contents (optional)

Environment variables:
- DB_NAME: Name of the database (default: myapp)
- DB_USER: Application database user (default: appuser)
- DB_PASSWORD: Password for the application user (default: dbuser123)
- DB_HOST: Database host (default: localhost)
- DB_PORT: Database port (default: 5000)
- PG_SUPERUSER_UNIX: Unix user with permission to run postgres utilities (default: postgres)
- SEED_DATA: When "true", startup.sh will apply seed.sql after the schema

Quick start:
1) Ensure PostgreSQL is running and reachable on DB_HOST:DB_PORT. If you are using a local cluster, the script can attempt to start it (depends on environment).
2) Run the setup:
   SEED_DATA=true ./startup.sh
   This will:
   - Wait for readiness
   - Create/update role and database
   - Apply schema.sql (idempotent)
   - Optionally apply seed.sql if SEED_DATA=true
   - Write connection helpers

Connection:
- Using psql:
  psql postgresql://appuser:dbuser123@localhost:5000/myapp
  or
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -p $DB_PORT
- After startup.sh completes, db_connection.txt will contain a ready-to-use psql command.
- db_visualizer/postgres.env is also written for the Node.js viewer:
  export POSTGRES_URL="postgresql://localhost:5000/myapp"
  export POSTGRES_USER="appuser"
  export POSTGRES_PASSWORD="dbuser123"
  export POSTGRES_DB="myapp"
  export POSTGRES_PORT="5000"

Schema application:
- startup.sh applies schema.sql with ON_ERROR_STOP so failures stop the script.
- The schema is designed to be idempotent (CREATE IF NOT EXISTS), so re-running is safe.

Optional seed data:
- A small set of sample artists, albums, and tracks is provided in seed.sql to quickly test queries and UIs.
- To enable seeding, set SEED_DATA=true before running startup.sh:
  SEED_DATA=true ./startup.sh
- You can also apply seed manually:
  psql postgresql://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME -f seed.sql

Backups and restore:
- backup_db.sh detects the running database and writes:
  - database_backup.sql for PostgreSQL/MySQL
  - database_backup.db for SQLite
  - database_backup.archive for MongoDB
- restore_db.sh performs the reverse: detects backup type and restores into the currently running database on DB_PORT. It attempts PostgreSQL first when SQL is detected, then MySQL, then SQLite, then MongoDB archive.

Troubleshooting:
- If postgres is managed externally (e.g., Docker), startup.sh will skip starting it and only wait for readiness.
- If permissions prevent creating extensions (uuid-ossp), the schema will continue without it and still function (UUID generation is part of the schema guarded block).
- Ensure DB_PORT matches your running instance. Defaults in this project use 5000 for convenience.

Note on security:
- Do not hardcode secrets for production. Provide DB_PASSWORD and other secrets through environment variables or a secret manager.
- Limit network exposure of PostgreSQL in production; the database should be reachable only by internal services.

