-- Runs once, on first cluster initialization only.

CREATE DATABASE mydb ENCODING 'UTF8' TEMPLATE template0;

\c mydb

-- EDB Postgres Advanced Server defaults to Oracle-compatible DATE semantics
-- (edb_redwood_date = on), where casting to ::date returns a full
-- timestamp (time component retained) instead of a true day-only date --
-- pg_typeof(now()::date) is "timestamp without time zone", not "date".
-- This silently breaks the extremely common `col::date = 'YYYY-MM-DD'`
-- filter pattern (any WHERE clause using it matches nothing unless the
-- time happens to be exactly midnight) -- found via demo 4's NL-to-SQL
-- queries, which use this pattern constantly, but it would bite any
-- hand-written SQL against this schema just as silently. Turn it off so
-- ::date behaves like standard Postgres for every session against mydb.
ALTER DATABASE mydb SET edb_redwood_date = off;
ALTER DATABASE mydb SET datestyle = 'iso, mdy';

CREATE EXTENSION IF NOT EXISTS aidb CASCADE;
CREATE EXTENSION IF NOT EXISTS pgfs;

-- aidb CASCADE pulls in pgvector as a dependency, but make sure it's
-- explicitly present and confirm the version for reference.
CREATE EXTENSION IF NOT EXISTS vector;

SELECT extname, extversion FROM pg_extension ORDER BY extname;
