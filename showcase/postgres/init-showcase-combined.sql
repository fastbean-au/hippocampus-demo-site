-- Runs once, on first boot of the shared Postgres container in
-- compose.showcase-combined.yaml (files in /docker-entrypoint-initdb.d/ execute against the
-- default POSTGRES_DB as the POSTGRES_USER). One cluster hosts ALL THREE showcases in separate
-- databases so their data never mixes and each consolidating instance takes its own
-- database-scoped advisory lock (see db/postgres.go — the lock key is fixed, but Postgres advisory
-- locks are scoped to the current database, so two databases do not collide).
CREATE DATABASE hippocampus_book;
CREATE DATABASE hippocampus_logs;
CREATE DATABASE hippocampus_bluesky;

-- The agent pair. Two databases rather than one, because they are two independent stores that must
-- each take their own advisory lock and must never see each other's rows - the whole point is what
-- each one INDEPENDENTLY chose to keep from identical input.
CREATE DATABASE hippocampus_agent;
CREATE DATABASE hippocampus_agent_flat;
