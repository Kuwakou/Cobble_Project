-- 110: Discussion Thread procedures. Three calls, matching the agreed API contract:
--   GET    /threads/{threadId}/comments              -> dsc.usp_Comment_List
--   POST   /threads/{threadId}/comments              -> dsc.usp_Comment_Add
--   DELETE /threads/{threadId}/comments/{commentId}  -> dsc.usp_Comment_Remove
--
-- Every procedure takes @TenantId as its FIRST parameter and every statement filters on it.
-- Identity (@TenantId, @AuthorMemberId, @AuthorDisplayName) comes from the JWT via the API -
-- never from the request body - so a caller cannot post as someone else.
--
-- Output contract (same envelope as the membership procedures): one row, one column [json],
--   {"ok":true,"data":<object|array>}  or  {"ok":false,"error":{"code":"...","message":"..."}}
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-------------------------------------------------------------------------------
-- Renders one comment as a JSON object, or NULL when the (TenantId, CommentId) pair
-- does not exist / is deleted. Both keys are always required: this is the tenancy fence.
-- createdUtc is emitted as ISO-8601 with an explicit Z, as agreed in the team contract.
-------------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dsc.tvf_CommentJson (@TenantId UNIQUEIDENTIFIER, @CommentId UNIQUEIDENTIFIER)
RETURNS TABLE
AS RETURN
(
    SELECT (
        SELECT c.CommentId                                 AS [commentId],
               c.ThreadId                                  AS [threadId],
               c.TenantId                                  AS [tenantId],
               c.AuthorMemberId                            AS [authorMemberId],
               c.AuthorDisplayName                         AS [authorName],
               c.Body                                      AS [body],
               CONVERT(NVARCHAR(19), c.CreatedAt, 126) + 'Z' AS [createdUtc]
        FROM dsc.Comment c
        WHERE c.TenantId = @TenantId AND c.CommentId = @CommentId AND c.IsDeleted = 0
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS [json]
);
GO

-------------------------------------------------------------------------------
-- dsc.usp_Comment_List
-- in : @TenantId, @ThreadId
-- out: [ CommentDto, ... ]  (empty array when the thread has no live comments)
--      not_found  when the thread does not exist IN THIS TENANT
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.usp_Comment_List
    @TenantId UNIQUEIDENTIFIER,
    @ThreadId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dsc.Thread WHERE TenantId = @TenantId AND ThreadId = @ThreadId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Thread not found in this tenant.') AS [json]; RETURN; END

    SELECT dbo.fn_JsonOk(ISNULL((
        SELECT c.CommentId                                 AS [commentId],
               c.ThreadId                                  AS [threadId],
               c.TenantId                                  AS [tenantId],
               c.AuthorMemberId                            AS [authorMemberId],
               c.AuthorDisplayName                         AS [authorName],
               c.Body                                      AS [body],
               CONVERT(NVARCHAR(19), c.CreatedAt, 126) + 'Z' AS [createdUtc]
        FROM dsc.Comment c
        WHERE c.TenantId = @TenantId AND c.ThreadId = @ThreadId AND c.IsDeleted = 0
        ORDER BY c.CreatedAt, c.CommentId
        FOR JSON PATH), N'[]')) AS [json];
END
GO

-------------------------------------------------------------------------------
-- dsc.usp_Comment_Add
-- in : @TenantId, @AuthorMemberId, @AuthorDisplayName (all from the JWT),
--      @ThreadId, @Json = { "body": "string(1..2000)" }
-- out: CommentDto  |  not_found (thread) | validation
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.usp_Comment_Add
    @TenantId          UNIQUEIDENTIFIER,
    @AuthorMemberId    UNIQUEIDENTIFIER,
    @AuthorDisplayName NVARCHAR(100),
    @ThreadId          UNIQUEIDENTIFIER,
    @Json              NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dsc.Thread WHERE TenantId = @TenantId AND ThreadId = @ThreadId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Thread not found in this tenant.') AS [json]; RETURN; END

    DECLARE @Body NVARCHAR(2000) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.body')));
    IF @Body IS NULL OR LEN(@Body) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'body is required (1-2000 characters).') AS [json]; RETURN; END

    DECLARE @Name NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@AuthorDisplayName)), N'');
    IF @Name IS NULL SET @Name = N'Member';

    DECLARE @Ids TABLE (CommentId UNIQUEIDENTIFIER);
    INSERT INTO dsc.Comment (TenantId, ThreadId, AuthorMemberId, AuthorDisplayName, Body)
    OUTPUT inserted.CommentId INTO @Ids
    VALUES (@TenantId, @ThreadId, @AuthorMemberId, @Name, @Body);

    DECLARE @CommentId UNIQUEIDENTIFIER = (SELECT TOP 1 CommentId FROM @Ids);
    SELECT dbo.fn_JsonOk([json]) AS [json] FROM dsc.tvf_CommentJson(@TenantId, @CommentId);
END
GO

-------------------------------------------------------------------------------
-- dsc.usp_Comment_Remove  (soft delete - the row is kept for audit)
-- in : @TenantId, @AuthorMemberId (from the JWT), @CommentId
-- out: { "deleted": true }
--      not_found  when the comment is absent, already deleted, or belongs to another tenant
--      forbidden  when the comment exists in this tenant but was written by someone else
--
-- NOTE for the team: authors may remove only their own comments. To let moderators remove any
-- comment, add a @CanModerate BIT parameter and skip the ownership check when it is 1.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.usp_Comment_Remove
    @TenantId       UNIQUEIDENTIFIER,
    @AuthorMemberId UNIQUEIDENTIFIER,
    @CommentId      UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @Owner UNIQUEIDENTIFIER = (
        SELECT AuthorMemberId FROM dsc.Comment
        WHERE TenantId = @TenantId AND CommentId = @CommentId AND IsDeleted = 0);

    IF @Owner IS NULL
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Comment not found in this tenant.') AS [json]; RETURN; END
    IF @Owner <> @AuthorMemberId
        BEGIN SELECT dbo.fn_JsonError('forbidden', 'A comment can only be removed by its author.') AS [json]; RETURN; END

    UPDATE dsc.Comment
    SET IsDeleted = 1, DeletedAt = SYSUTCDATETIME()
    WHERE TenantId = @TenantId AND CommentId = @CommentId AND IsDeleted = 0;

    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Comment not found in this tenant.') AS [json];
    ELSE
        SELECT dbo.fn_JsonOk(N'{"deleted":true}') AS [json];
END
GO
