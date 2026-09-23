-- Worked examples for the API team: every discussion procedure, with the exact JSON it returns.
-- This file is the DB->API handover artefact. Run it as sa inside the sql container:
--   docker exec -it cobble-sql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$env:SA_PASSWORD" \
--       -C -b -d Cobble398 -i /usr/src/app/tests/discussion-examples.sql
--
-- Seeded ids (see 120-discussion-seed.sql):
--   Tenant A  11111111-1111-1111-1111-111111111111
--   Thread A  AAAA0001-0000-0000-0000-000000000001
--   Ana       00000000-0000-0000-0000-0000000000A1
--   Ben       00000000-0000-0000-0000-0000000000B2
--   Tenant B  22222222-2222-2222-2222-222222222222  (isolation control)
USE Cobble398;
SET NOCOUNT ON;

DECLARE @Tenant UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @Other  UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
DECLARE @Thread UNIQUEIDENTIFIER = 'AAAA0001-0000-0000-0000-000000000001';
DECLARE @Ana    UNIQUEIDENTIFIER = '00000000-0000-0000-0000-0000000000A1';
DECLARE @Ben    UNIQUEIDENTIFIER = '00000000-0000-0000-0000-0000000000B2';
DECLARE @r TABLE ([json] NVARCHAR(MAX));
DECLARE @NewId UNIQUEIDENTIFIER;

-------------------------------------------------------------------------------
-- 1. GET /threads/{threadId}/comments   ->   dsc.usp_Comment_List
-------------------------------------------------------------------------------
PRINT '--- 1. usp_Comment_List (happy path) -> HTTP 200, data = array ---';
EXEC dsc.usp_Comment_List @TenantId = @Tenant, @ThreadId = @Thread;
-- {"ok":true,"data":[
--   {"commentId":"C0000001-...-0001","threadId":"AAAA0001-...","tenantId":"11111111-...",
--    "authorMemberId":"00000000-...-00A1","authorName":"Ana Nguyen",
--    "body":"Kicking this off: ...","createdUtc":"2026-09-01T09:00:00Z"}, ... ]}

PRINT '--- 1b. usp_Comment_List with the WRONG tenant -> HTTP 404 ---';
EXEC dsc.usp_Comment_List @TenantId = @Other, @ThreadId = @Thread;
-- {"ok":false,"error":{"code":"not_found","message":"Thread not found in this tenant."}}

-------------------------------------------------------------------------------
-- 2. POST /threads/{threadId}/comments   ->   dsc.usp_Comment_Add
--    Identity parameters come from the JWT; only "body" comes from the request body.
-------------------------------------------------------------------------------
PRINT '--- 2. usp_Comment_Add (happy path) -> HTTP 201, data = the created comment ---';
INSERT @r EXEC dsc.usp_Comment_Add
      @TenantId          = @Tenant,
      @AuthorMemberId    = @Ben,
      @AuthorDisplayName = N'Ben Okafor',
      @ThreadId          = @Thread,
      @Json              = N'{"body":"Added from the examples script."}';
SELECT [json] AS [usp_Comment_Add] FROM @r;
SELECT @NewId = JSON_VALUE([json], '$.data.commentId') FROM @r;
-- {"ok":true,"data":{"commentId":"<new guid>","threadId":"AAAA0001-...","tenantId":"11111111-...",
--                    "authorMemberId":"00000000-...-00B2","authorName":"Ben Okafor",
--                    "body":"Added from the examples script.","createdUtc":"2026-..."}}

PRINT '--- 2b. usp_Comment_Add with a blank body -> HTTP 400 ---';
EXEC dsc.usp_Comment_Add @Tenant, @Ben, N'Ben Okafor', @Thread, N'{"body":"  "}';
-- {"ok":false,"error":{"code":"validation","message":"body is required (1-2000 characters)."}}

PRINT '--- 2c. usp_Comment_Add with a malformed body -> HTTP 400 ---';
EXEC dsc.usp_Comment_Add @Tenant, @Ben, N'Ben Okafor', @Thread, N'not json';
-- {"ok":false,"error":{"code":"validation","message":"Body must be a JSON object."}}

-------------------------------------------------------------------------------
-- 3. DELETE /threads/{threadId}/comments/{commentId}   ->   dsc.usp_Comment_Remove
-------------------------------------------------------------------------------
PRINT '--- 3. usp_Comment_Remove by a DIFFERENT member -> HTTP 403 ---';
EXEC dsc.usp_Comment_Remove @TenantId = @Tenant, @AuthorMemberId = @Ana, @CommentId = @NewId;
-- {"ok":false,"error":{"code":"forbidden","message":"A comment can only be removed by its author."}}

PRINT '--- 3b. usp_Comment_Remove by the author -> HTTP 204 ---';
EXEC dsc.usp_Comment_Remove @TenantId = @Tenant, @AuthorMemberId = @Ben, @CommentId = @NewId;
-- {"ok":true,"data":{"deleted":true}}

PRINT '--- 3c. removing it again -> HTTP 404 ---';
EXEC dsc.usp_Comment_Remove @TenantId = @Tenant, @AuthorMemberId = @Ben, @CommentId = @NewId;
-- {"ok":false,"error":{"code":"not_found","message":"Comment not found in this tenant."}}

PRINT '--- 3d. the thread is back to its seeded 4 comments ---';
EXEC dsc.usp_Comment_List @TenantId = @Tenant, @ThreadId = @Thread;

-------------------------------------------------------------------------------
-- Error code -> HTTP status mapping for the API layer
-------------------------------------------------------------------------------
--   ok:true on List / Add      -> 200 / 201 with data
--   ok:true on Remove          -> 204 (no body)
--   validation                 -> 400
--   forbidden                  -> 403
--   not_found                  -> 404
--   anything else / exception  -> 500 (log it, do not leak the SQL message)
