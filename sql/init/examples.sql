-- Discussion Thread PoC — db/examples.sql
-- Literal EXEC calls for all three procedures and the JSON they return.
-- This is what the API pastes/adapts into its stored-procedure calls.
-- Run against the DiscussionPoC database.

USE DiscussionPoC;
GO

-- 1) Read all comments in tenant A's thread
EXEC dsc.Comments_GetByThread_JSON
    @TenantId = '11111111-1111-1111-1111-111111111111',
    @ThreadId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
-- Example JSON returned (array):
-- [
--   {"commentId":"...","threadId":"aaaaaaaa-...","tenantId":"11111111-...",
--    "authorMemberId":"30000000-...","authorName":"Jane",
--    "body":"Kicking off the thread — welcome!","createdUtc":"2026-09-21T04:10:00.000Z"},
--   ...
-- ]

-- 2) Create a new comment (tenantId/authorMemberId supplied by the API from
--    the JWT — hard-coded here to tenant A / Jane for the example)
EXEC dsc.Comments_Create_JSON
    @TenantId  = '11111111-1111-1111-1111-111111111111',
    @MemberId  = '30000000-0000-0000-0000-000000000001',
    @ThreadId  = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    @Input     = N'{"body":"Example comment from examples.sql","authorName":"Jane"}';
-- Example JSON returned (single object):
-- {"commentId":"...","threadId":"aaaaaaaa-...","tenantId":"11111111-...",
--  "authorMemberId":"30000000-...","authorName":"Jane",
--  "body":"Example comment from examples.sql","createdUtc":"2026-09-21T04:40:00.000Z"}

-- 3) Delete a comment (replace @CommentId with a real commentId from step 1 or 2)
-- EXEC dsc.Comments_Delete_JSON
--     @TenantId  = '11111111-1111-1111-1111-111111111111',
--     @MemberId  = '30000000-0000-0000-0000-000000000001',
--     @CommentId = '<paste-a-real-commentId-here>';
-- Example JSON returned:
-- {"deleted":1}
GO
