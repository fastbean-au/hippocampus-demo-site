-- Runs once, on first boot of the shared Postgres container in
-- docker-compose.showcase-combined.yaml (files in /docker-entrypoint-initdb.d/ execute against the
-- default POSTGRES_DB as the POSTGRES_USER). One cluster hosts BOTH showcases in separate databases
-- so the book and logs data never mix and each consolidating instance takes its own
-- database-scoped advisory lock (see db/postgres.go — the lock key is fixed, but Postgres advisory
-- locks are scoped to the current database, so two databases do not collide).
CREATE DATABASE hippocampus_book;
CREATE DATABASE hippocampus_logs;
