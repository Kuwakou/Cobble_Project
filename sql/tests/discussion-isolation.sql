-- Negative tenant-isolation test for the discussion thread module (Week 13 PoC). Run as sa:
--   sqlcmd -S localhost -U sa -P ... -C -b -d Cobble398 -i /usr/src/app/tests/discussion-isolation.sql
-- Every case tries to reach Tenant A's thread while claiming to be Tenant B, through every path the
-- API exposes. Expected result for each: not_found / forbidden, and Tenant A's data untouched.
-- Uses its own throw-away tenants so the seeded PoC data in 120-discussion-seed.sql is left alone.
-- Exit code is non-zero if any case fails (THROW at the end + sqlcmd -b).
USE Cobble398;
SET NOCOUNT ON;

DECLARE @A  UNIQUEIDENTIFIER = 'DDDDDDDD-0000-4000-8000-0000000000DA';  -- victim tenant
DECLARE @B  UNIQUEIDENTIFIER = 'EEEEEEEE-0000-4000-8000-0000000000EB';  -- attacking tenant
DECLARE @TA UNIQUEIDENTIFIER = 'DDDDDDDD-1111-4000-8000-00000000000A';  -- thread in A
DECLARE @TB UNIQUEIDENTIFIER = 'EEEEEEEE-1111-4000-8000-00000000000B';  -- thread in B
DECLARE @MA UNIQUEIDENTIFIER = 'DDDDDDDD-2222-4000-8000-00000000000A';  -- member of A (author)
DECLARE @M2 UNIQUEIDENTIFIER = 'DDDDDDDD-2222-4000-8000-00000000000C';  -- another member of A
DECLARE @MB UNIQUEIDENTIFIER = 'EEEEEEEE-2222-4000-8000-00000000000B';  -- member of B

DECLARE @r TABLE ([json] NVARCHAR(MAX));
DECLARE @j NVARCHAR(MAX), @fail INT = 0, @pass INT = 0, @n INT;
DECLARE @CommentId UNIQUEIDENTIFIER;

-- clean slate (cascades to dsc.Comment)
DELETE FROM dsc.Thread WHERE TenantId IN (@A, @B);

PRINT '=== Discussion thread: negative tenant isolation test ===';

-------------------------------------------------------------------------------
-- T01 setup: one thread per tenant, one comment authored by MA in tenant A
-------------------------------------------------------------------------------
INSERT INTO dsc.Thread (TenantId, ThreadId, Title) VALUES (@A, @TA, N'Tenant A thread');
INSERT INTO dsc.Thread (TenantId, ThreadId, Title) VALUES (@B, @TB, N'Tenant B thread');
INSERT @r EXEC dsc.usp_Comment_Add @A, @MA, N'Alice (tenant A)', @TA, N'{"body":"Alice original comment"}';
SELECT @CommentId = JSON_VALUE([json], '$.data.commentId'), @j = [json] FROM @r;
IF @CommentId IS NOT NULL AND JSON_VALUE(@j, '$.data.authorName') = N'Alice (tenant A)'
    BEGIN SET @pass += 1; PRINT 'PASS T01 setup: thread in A and B, one comment authored by MA'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T01 setup: ' + ISNULL(@j, 'null'); END

-------------------------------------------------------------------------------
-- T02 cross-tenant read of the thread
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_List @B, @TA;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.ok') = 'false' AND JSON_VALUE(@j, '$.error.code') = 'not_found'
    BEGIN SET @pass += 1; PRINT 'PASS T02 usp_Comment_List(B, threadOfA) -> not_found'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T02 usp_Comment_List(B, threadOfA) returned: ' + @j; END

-------------------------------------------------------------------------------
-- T03 B's own thread must not leak A's comment
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_List @B, @TB;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.ok') = 'true' AND @j NOT LIKE '%Alice original comment%'
    BEGIN SET @pass += 1; PRINT 'PASS T03 usp_Comment_List(B, threadOfB) shows B only'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T03 usp_Comment_List(B, threadOfB) leaked: ' + @j; END

-------------------------------------------------------------------------------
-- T04 cross-tenant ADD (B posts into A's thread using A's real ThreadId)
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Add @B, @MB, N'Bob (tenant B)', @TA, N'{"body":"injected"}';
SELECT @j = [json] FROM @r;
SELECT @n = COUNT(*) FROM dsc.Comment WHERE ThreadId = @TA;
IF JSON_VALUE(@j, '$.error.code') = 'not_found' AND @n = 1
    BEGIN SET @pass += 1; PRINT 'PASS T04 usp_Comment_Add(B, threadOfA) -> not_found, no row added'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T04 ' + @j + ' (rows in thread A: ' + CAST(@n AS NVARCHAR(10)) + ')'; END

-------------------------------------------------------------------------------
-- T05 cross-tenant REMOVE using A's real CommentId (IDOR attempt)
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Remove @B, @MB, @CommentId;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'not_found'
   AND EXISTS (SELECT 1 FROM dsc.Comment WHERE CommentId = @CommentId AND IsDeleted = 0)
    BEGIN SET @pass += 1; PRINT 'PASS T05 usp_Comment_Remove(B, realCommentId) -> not_found, comment intact'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T05 ' + @j; END

-------------------------------------------------------------------------------
-- T06 same tenant, wrong author: ownership is enforced as well as tenancy
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Remove @A, @M2, @CommentId;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'forbidden'
   AND EXISTS (SELECT 1 FROM dsc.Comment WHERE CommentId = @CommentId AND IsDeleted = 0)
    BEGIN SET @pass += 1; PRINT 'PASS T06 usp_Comment_Remove(A, otherMember) -> forbidden, comment intact'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T06 ' + @j; END

-------------------------------------------------------------------------------
-- T07 validation: an empty body is rejected before anything is written
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Add @A, @MA, N'Alice (tenant A)', @TA, N'{"body":"   "}';
SELECT @j = [json] FROM @r;
SELECT @n = COUNT(*) FROM dsc.Comment WHERE ThreadId = @TA;
IF JSON_VALUE(@j, '$.error.code') = 'validation' AND @n = 1
    BEGIN SET @pass += 1; PRINT 'PASS T07 usp_Comment_Add with blank body -> validation, nothing written'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T07 ' + @j; END

-------------------------------------------------------------------------------
-- T08 engine-level fence: a comment cannot point at a thread in another tenant
-------------------------------------------------------------------------------
BEGIN TRY
    INSERT INTO dsc.Comment (TenantId, ThreadId, AuthorMemberId, AuthorDisplayName, Body)
    VALUES (@B, @TA, @MB, N'Bob (tenant B)', N'cross-tenant row');
    SET @fail += 1; PRINT 'FAIL T08 direct INSERT with mismatched TenantId was accepted';
    DELETE FROM dsc.Comment WHERE TenantId = @B AND ThreadId = @TA;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 547
        BEGIN SET @pass += 1; PRINT 'PASS T08 direct INSERT (TenantId=B, ThreadId=A) rejected by FK_Comment_Thread (error 547)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T08 unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE(); END
END CATCH

-------------------------------------------------------------------------------
-- T09 NULL tenant is impossible
-------------------------------------------------------------------------------
BEGIN TRY
    INSERT INTO dsc.Thread (TenantId, ThreadId, Title) VALUES (NULL, NEWID(), N'no tenant');
    SET @fail += 1; PRINT 'FAIL T09 NULL TenantId accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 515
        BEGIN SET @pass += 1; PRINT 'PASS T09 INSERT with NULL TenantId rejected (error 515)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T09 unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)); END
END CATCH

-------------------------------------------------------------------------------
-- T10 permission fence: the API login cannot touch dsc tables, but can execute dsc procedures
-------------------------------------------------------------------------------
EXECUTE AS USER = 'cobble_api';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dsc.Comment;
    SET @fail += 1; PRINT 'FAIL T10a cobble_api could SELECT from dsc.Comment';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 229
        BEGIN SET @pass += 1; PRINT 'PASS T10a cobble_api SELECT on dsc.Comment denied (error 229)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T10a unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)); END
END CATCH
BEGIN TRY
    DELETE @r; INSERT @r EXEC dsc.usp_Comment_List @A, @TA;
    SELECT @j = [json] FROM @r;
    IF JSON_VALUE(@j, '$.ok') = 'true' AND @j LIKE '%Alice original comment%'
        BEGIN SET @pass += 1; PRINT 'PASS T10b cobble_api EXEC usp_Comment_List(A, threadOfA) -> ok (ownership chaining)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T10b ' + ISNULL(@j, 'null'); END
END TRY
BEGIN CATCH
    SET @fail += 1; PRINT 'FAIL T10b error ' + ERROR_MESSAGE();
END CATCH
REVERT;

-------------------------------------------------------------------------------
-- T11 positive control: the author can remove their own comment, and it is a SOFT delete
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Remove @A, @MA, @CommentId;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.data.deleted') = 'true'
   AND EXISTS (SELECT 1 FROM dsc.Comment WHERE CommentId = @CommentId AND IsDeleted = 1 AND DeletedAt IS NOT NULL)
    BEGIN SET @pass += 1; PRINT 'PASS T11a usp_Comment_Remove(A, author) -> deleted, row retained with IsDeleted = 1'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T11a ' + @j; END

DELETE @r; INSERT @r EXEC dsc.usp_Comment_List @A, @TA;
SELECT @j = [json] FROM @r;
-- CHARINDEX, not LIKE: in T-SQL LIKE, '[]' is an empty character class and never matches.
IF JSON_VALUE(@j, '$.ok') = 'true' AND CHARINDEX('"data":[]', @j) > 0
    BEGIN SET @pass += 1; PRINT 'PASS T11b removed comment no longer appears in the thread'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T11b ' + @j; END

-- a second remove of the same comment must not succeed twice
DELETE @r; INSERT @r EXEC dsc.usp_Comment_Remove @A, @MA, @CommentId;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'not_found'
    BEGIN SET @pass += 1; PRINT 'PASS T11c removing an already-removed comment -> not_found'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T11c ' + @j; END

-- cleanup
DELETE FROM dsc.Thread WHERE TenantId IN (@A, @B);

PRINT '=== Result: ' + CAST(@pass AS NVARCHAR(10)) + ' passed, ' + CAST(@fail AS NVARCHAR(10)) + ' failed ===';
IF @fail > 0 THROW 50001, 'Discussion tenant isolation test FAILED', 1;
