-- Discussion Thread PoC — db/negative_test.sql
-- Cross-tenant isolation checks. Expected results are documented inline;
-- screenshot the actual output for /evidence per Stage C.

USE DiscussionPoC;
GO

-- 1) Read tenant A's thread using tenant B's id -> expect ZERO rows.
--    (Tenant B does not own threadId aaaaaaaa-..., so this also proves the
--    WHERE TenantId=@TenantId clause, not just a wrong threadId, is doing the work.)
PRINT 'Expected: [] (zero rows)';
EXEC dsc.Comments_GetByThread_JSON
    @TenantId = '22222222-2222-2222-2222-222222222222',
    @ThreadId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
GO

-- 2) Attempt to delete a tenant-A comment while posing as tenant B ->
--    expect {"deleted":0}, and the comment must still be readable under
--    tenant A afterwards (uncomment and paste a real commentId to confirm).
DECLARE @VictimCommentId UNIQUEIDENTIFIER = (
    SELECT TOP 1 CommentId FROM dsc.Comments
    WHERE TenantId = '11111111-1111-1111-1111-111111111111' AND IsDeleted = 0
);
PRINT 'Expected: {"deleted":0} — cross-tenant delete must be refused';
EXEC dsc.Comments_Delete_JSON
    @TenantId  = '22222222-2222-2222-2222-222222222222',
    @MemberId  = '40000000-0000-0000-0000-000000000001',
    @CommentId = @VictimCommentId;
GO

-- 3) Confirm the "victim" comment from step 2 is still present under its
--    real tenant (A) — proves step 2 did not delete it.
PRINT 'Expected: the victim comment still appears (not deleted)';
EXEC dsc.Comments_GetByThread_JSON
    @TenantId = '11111111-1111-1111-1111-111111111111',
    @ThreadId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
GO
