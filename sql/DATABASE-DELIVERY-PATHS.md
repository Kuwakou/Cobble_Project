# Database delivery paths: no-rls, rls, and live

Modelled on the Cobbled EDP reference module's `docs/database-delivery-paths.md`.
These three paths build **only** the `dsc` schema (the Discussion Thread module) -
they don't touch `sql/init/*.sql` or anything else in this repo, which is a
separate, currently-unwired build for a different schema (`Cobble398`).

| Path | Target | Row isolation | Use it for |
|---|---|---|---|
| `no-rls/build.sql` | `DiscussionPoC` | App/proc filters by `TenantID` only - SQL Server does not block a cross-tenant query by itself | Local development, debugging, seeding |
| `rls/build.sql` | a database you point `SQL_DATABASE` at for this | SQL Server Row-Level Security, enforced from `SESSION_CONTEXT`, independent of application code | Proving tenant isolation actually holds, not just that the app remembers to filter |
| `live/` | — | — | Placeholder only; see `live/README.md`. There's no real production deployment pipeline for this course project |

## How the API picks one

`docker-compose.yml`'s `sql-init` service reads `DB_BUILD_PATH` (default `no-rls`)
and runs `/init/$DB_BUILD_PATH/build.sql`. To exercise the RLS path instead:

```bash
DB_BUILD_PATH=rls docker compose down
DB_BUILD_PATH=rls docker compose up -d --build
```

(Set it in `.env` instead of the shell if you want it to stick.)

## What no-rls means

NoRLS means Row-Level Security is **intentionally not enabled**. It does not mean
"no security": the API still only accepts a signed, validated identity (see
`api/app/identity.py`) and still pushes `TenantID`/`MemberID` into
`SESSION_CONTEXT` before calling `dsc.dsc_Comment_CRUD_JSON`, which still filters
every statement by `TenantID`. What's missing is the engine-level backstop: a
query that forgot `WHERE TenantID = ...` would just work here instead of being
blocked. That's an acceptable trade for a fast local dev loop; it's not an
acceptable trade for proving tenant isolation.

## What rls adds

`rls/build.sql` runs `no-rls/build.sql` first (so the table/proc/seed exist),
then adds `dsc.fn_Comment_TenantPredicate` and a `CREATE SECURITY POLICY` that
filters and blocks every read/write against `dsc.dsc_Comment` to the tenant in
`SESSION_CONTEXT('TenantID')` - for every login, with no sysadmin bypass. That
works here because the API always sets `SESSION_CONTEXT` from the caller's
validated token before it queries, so the predicate always has a real value.
This is the path to run before trusting a tenant-isolation claim.

## Boundary

Both paths create or use the `dsc` schema only. Neither touches the `Cobble398`
database or the `sql/init/*.sql` scripts your teammate built for it - see
`README-discussion.md` for that separate, currently-disconnected setup.
