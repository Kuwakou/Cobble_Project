# Discussion Thread — database container (Week 13 PoC)

The discussion-thread objects live in the **existing `sql` container**, not a new one: the syllabus
allows exactly one SQL container per compose file. They are added as extra idempotent init scripts,
in their own schema `dsc`, so the module boundary is visible without a second database.

## Run it

```bash
docker compose up -d --build sql
```

`sql/entrypoint.sh` starts SQL Server, waits for recovery, then applies every `sql/init/*.sql` in
lexical order — on **every** start, because all scripts are idempotent. Nothing to run by hand.

## What was added

| File | Purpose |
|---|---|
| `init/100-discussion-tables.sql` | Schema `dsc`, tables `dsc.Thread` and `dsc.Comment`, tenancy guard |
| `init/110-procs-discussion.sql` | `usp_Comment_List`, `usp_Comment_Add`, `usp_Comment_Remove` + `tvf_CommentJson` |
| `init/120-discussion-seed.sql` | Two tenants, one thread each, 5 comments — fixed GUIDs, MERGE-based so re-runs are no-ops |
| `init/190-discussion-security.sql` | `GRANT EXECUTE ON SCHEMA::dsc` / `DENY` every table verb, for the `cobble_api` login |
| `tests/discussion-isolation.sql` | 14 negative + positive assertions; non-zero exit on failure |
| `tests/discussion-examples.sql` | Every procedure with the exact JSON it returns — the DB→API handover artefact |

## Data model

```
dsc.Thread (TenantId, ThreadId)                    PK (TenantId, ThreadId)
    |
    +-- dsc.Comment (TenantId, CommentId)          PK (TenantId, CommentId)
        FK (TenantId, ThreadId) -> dsc.Thread      composite, so a comment can never
                                                   attach to another tenant's thread
```

Design decisions worth defending in the report:

- **`TenantId UNIQUEIDENTIFIER NOT NULL` is the leading key column of both tables.** A guard at the
  end of `100-discussion-tables.sql` fails the deployment if any `dsc` table lacks it.
- **The FK is composite `(TenantId, ThreadId)`**, not just `ThreadId`. Cross-tenant attachment is
  rejected by the engine (error 547), not merely by procedure logic — proven by test T08.
- **Soft delete.** `IsDeleted` + `DeletedAt`; rows are never physically removed, so the audit trail
  survives. Every read filters `IsDeleted = 0`. A `CHECK` keeps the two columns consistent.
- **No FK to `dbo.Member`.** The discussion module stores a `AuthorMemberId` reference plus a
  denormalised `AuthorDisplayName` snapshot; member profile is owned by the membership context.
- **RLS is not used.** Isolation is enforced by `@TenantId` being a required parameter of every
  procedure plus the composite keys, and the API login is denied all direct table access — so there
  is no code path that could bypass the filter. RLS would add a second enforcement mechanism to keep
  in sync for no additional guarantee at this scale. (This is the "when NOT to use RLS" note the
  DBA role is asked to document.)

## Procedure contract

All three return **one row, one column `[json]`**, using the same envelope as the membership
procedures: `{"ok":true,"data":…}` or `{"ok":false,"error":{"code":…,"message":…}}`.

| API route | Procedure | Parameters |
|---|---|---|
| `GET /threads/{threadId}/comments` | `dsc.usp_Comment_List` | `@TenantId, @ThreadId` |
| `POST /threads/{threadId}/comments` | `dsc.usp_Comment_Add` | `@TenantId, @AuthorMemberId, @AuthorDisplayName, @ThreadId, @Json` |
| `DELETE /threads/{threadId}/comments/{commentId}` | `dsc.usp_Comment_Remove` | `@TenantId, @AuthorMemberId, @CommentId` |

`@TenantId`, `@AuthorMemberId` and `@AuthorDisplayName` come from **JWT claims**, never from the
request body. Only `{"body": "..."}` comes from the client.

Error code → HTTP status: `validation` → 400, `forbidden` → 403, `not_found` → 404, otherwise 500.

## Seeded ids

| | Id |
|---|---|
| Tenant A | `11111111-1111-1111-1111-111111111111` |
| Thread A (the PoC thread) | `AAAA0001-0000-0000-0000-000000000001` |
| Ana Nguyen | `00000000-0000-0000-0000-0000000000A1` |
| Ben Okafor | `00000000-0000-0000-0000-0000000000B2` |
| Tenant B (isolation control) | `22222222-2222-2222-2222-222222222222` |
| Thread B | `BBBB0001-0000-0000-0000-000000000001` |

Tenant B exists so the negative test has something to *not* return.

## Verify

```bash
docker exec -i cobble-sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -b -d Cobble398 -i /usr/src/app/tests/discussion-isolation.sql
```

Expected tail: `=== Result: 14 passed, 0 failed ===`, exit code 0. Capture the output into
`evidence/week-13/` alongside the examples run.

## Known gap for the team

`docker-compose.yml` marks `sql` healthy as soon as the `Cobble398` database exists, which happens in
`000-database.sql` — before the procedures are created. The API can therefore start a second or two
before `dsc` is ready. One-line fix when the team is ready to touch compose:

```yaml
test: ["CMD-SHELL", "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"$$MSSQL_SA_PASSWORD\" -C -b -d Cobble398 -Q \"SET NOCOUNT ON; IF OBJECT_ID('dsc.usp_Comment_List') IS NULL THROW 50000,'init incomplete',1\" > /dev/null"]
```
