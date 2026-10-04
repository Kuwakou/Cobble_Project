/* Discussion Thread module - developer NoRLS install. Target: DiscussionPoC.
   Mirrors the Cobbled EDP reference module's build-script shape:
     - char(32) IDs (a GUID with the dashes stripped), not UNIQUEIDENTIFIER
     - one dsc_<Table>_CRUD_JSON proc per table, @Action + @Payload
     - TenantID/MemberID come from SESSION_CONTEXT, never as explicit params
       and never from the request body
   NoRLS means SQL Server Row-Level Security is intentionally NOT enabled here.
   The API still only ever calls this proc with an identity it already validated
   from a signed context, and the proc still filters every row by TenantID - but
   nothing stops a direct query from reading another tenant's rows. That's fine
   for local development; see ../rls/build.sql for the isolation-tested path. */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF DB_ID('DiscussionPoC') IS NULL
BEGIN
    CREATE DATABASE DiscussionPoC;
END
GO

USE DiscussionPoC;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dsc')
    EXEC('CREATE SCHEMA dsc');
GO

IF OBJECT_ID('dsc.dsc_Comment', 'U') IS NULL
CREATE TABLE dsc.dsc_Comment (
    CommentID         char(32)      NOT NULL PRIMARY KEY,
    TenantID          char(32)      NOT NULL,
    ThreadID          char(32)      NOT NULL,
    ParentCommentID   char(32)      NULL,
    AuthorMemberID    char(32)      NOT NULL,
    AuthorName        nvarchar(100) NOT NULL,
    Body              nvarchar(2000) NOT NULL,
    IsDeleted         bit           NOT NULL CONSTRAINT DF_dsc_Comment_Deleted DEFAULT 0,
    CreatedUtc        datetime2(0)  NOT NULL CONSTRAINT DF_dsc_Comment_Created DEFAULT sysutcdatetime(),
    UpdatedUtc        datetime2(0)  NOT NULL CONSTRAINT DF_dsc_Comment_Updated DEFAULT sysutcdatetime(),
    CONSTRAINT FK_dsc_Comment_Parent FOREIGN KEY (ParentCommentID) REFERENCES dsc.dsc_Comment (CommentID)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_dsc_Comment_Thread' AND object_id = OBJECT_ID('dsc.dsc_Comment'))
    CREATE INDEX IX_dsc_Comment_Thread ON dsc.dsc_Comment (TenantID, ThreadID, CreatedUtc);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_dsc_Comment_Parent' AND object_id = OBJECT_ID('dsc.dsc_Comment'))
    CREATE INDEX IX_dsc_Comment_Parent ON dsc.dsc_Comment (TenantID, ParentCommentID) WHERE ParentCommentID IS NOT NULL;
GO

-------------------------------------------------------------------------------
-- dsc.dsc_Comment_CRUD_JSON
-- Single action-dispatch proc, like EDP's edp_ExampleItem_CRUD_JSON. The API
-- sets TenantID/MemberID into SESSION_CONTEXT (via sp_set_session_context)
-- right after it validates the caller's signed token; this proc only ever
-- reads them back out, it never accepts them as parameters.
--
-- @Action: SELECT | INSERT | DELETE
--   SELECT @Payload = { "threadId": "..." }
--   INSERT @Payload = { "threadId": "...", "body": "...", "authorName": "...",
--                       "parentCommentId": "..." | null }
--   DELETE @Payload = { "commentId": "..." }
--
-- One flat level of replies only: INSERT rejects a parentCommentId that is
-- itself a reply (THROW 50004), the same rule the earlier three-proc version
-- enforced - just re-homed into this single proc.
-- There's no UPDATE action because the UI has no comment-edit feature yet;
-- add one the same way INSERT/DELETE are written here if that changes.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.dsc_Comment_CRUD_JSON
    @Action  varchar(12),
    @Payload nvarchar(max) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TenantID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'TenantID'));
    DECLARE @MemberID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'MemberID'));
    IF @TenantID IS NULL OR @MemberID IS NULL
        THROW 50001, 'DSC_CONTEXT_REQUIRED', 1;

    IF @Action = 'SELECT'
    BEGIN
        DECLARE @ThreadID char(32) = JSON_VALUE(@Payload, '$.threadId');
        IF @ThreadID IS NULL
            THROW 50002, 'DSC_THREAD_ID_REQUIRED', 1;

        SELECT CommentID       AS commentId,
               ThreadID        AS threadId,
               TenantID        AS tenantId,
               AuthorMemberID  AS authorMemberId,
               AuthorName      AS authorName,
               Body            AS body,
               ParentCommentID AS parentCommentId,
               CreatedUtc      AS createdUtc
        FROM dsc.dsc_Comment
        WHERE TenantID = @TenantID AND ThreadID = @ThreadID AND IsDeleted = 0
        ORDER BY CreatedUtc
        FOR JSON PATH, INCLUDE_NULL_VALUES;
    END
    ELSE IF @Action = 'INSERT'
    BEGIN
        DECLARE @InsThreadID char(32) = JSON_VALUE(@Payload, '$.threadId');
        DECLARE @Body nvarchar(2000) = LTRIM(RTRIM(JSON_VALUE(@Payload, '$.body')));
        DECLARE @AuthorName nvarchar(100) = ISNULL(JSON_VALUE(@Payload, '$.authorName'), N'Member');
        DECLARE @ParentCommentID char(32) = JSON_VALUE(@Payload, '$.parentCommentId');

        IF @InsThreadID IS NULL
            THROW 50002, 'DSC_THREAD_ID_REQUIRED', 1;
        IF @Body IS NULL OR LEN(@Body) = 0
            THROW 50003, 'DSC_BODY_REQUIRED', 1;
        IF @ParentCommentID IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dsc.dsc_Comment
            WHERE TenantID = @TenantID AND ThreadID = @InsThreadID AND CommentID = @ParentCommentID
              AND IsDeleted = 0 AND ParentCommentID IS NULL)
            THROW 50004, 'DSC_PARENT_COMMENT_INVALID', 1;

        DECLARE @NewID char(32) = REPLACE(CONVERT(varchar(36), NEWID()), '-', '');

        INSERT INTO dsc.dsc_Comment (CommentID, TenantID, ThreadID, ParentCommentID, AuthorMemberID, AuthorName, Body)
        VALUES (@NewID, @TenantID, @InsThreadID, @ParentCommentID, @MemberID, @AuthorName, @Body);

        SELECT CommentID       AS commentId,
               ThreadID        AS threadId,
               TenantID        AS tenantId,
               AuthorMemberID  AS authorMemberId,
               AuthorName      AS authorName,
               Body            AS body,
               ParentCommentID AS parentCommentId,
               CreatedUtc      AS createdUtc
        FROM dsc.dsc_Comment
        WHERE CommentID = @NewID
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;
    END
    ELSE IF @Action = 'DELETE'
    BEGIN
        DECLARE @DelCommentID char(32) = JSON_VALUE(@Payload, '$.commentId');
        DECLARE @Owner char(32) = (
            SELECT AuthorMemberID FROM dsc.dsc_Comment
            WHERE TenantID = @TenantID AND CommentID = @DelCommentID AND IsDeleted = 0);

        IF @Owner IS NULL
            THROW 50005, 'DSC_COMMENT_NOT_FOUND', 1;
        IF @Owner <> @MemberID
            THROW 50006, 'DSC_COMMENT_FORBIDDEN', 1;

        UPDATE dsc.dsc_Comment
        SET IsDeleted = 1, UpdatedUtc = sysutcdatetime()
        WHERE TenantID = @TenantID AND CommentID = @DelCommentID;

        SELECT @DelCommentID AS commentId, CAST(1 AS bit) AS deleted
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
    END
    ELSE
        THROW 50099, 'DSC_ACTION_INVALID', 1;
END
GO

-------------------------------------------------------------------------------
-- Seed data - two tenants, one thread each, char(32) IDs (dashes stripped
-- from the same GUIDs the UNIQUEIDENTIFIER-era seed used, so Swagger/UI
-- examples you may already have typed still look familiar).
--   Tenant A: 11111111111111111111111111111111  Thread A: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
--   Tenant B: 22222222222222222222222222222222  Thread B: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
-------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dsc.dsc_Comment WHERE TenantID = '11111111111111111111111111111111')
BEGIN
    INSERT INTO dsc.dsc_Comment (CommentID, TenantID, ThreadID, AuthorMemberID, AuthorName, Body, CreatedUtc)
    VALUES
    (REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), '11111111111111111111111111111111', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
     '30000000000000000000000000000001', 'Jane', 'Kicking off the thread — welcome!', DATEADD(MINUTE, -30, SYSUTCDATETIME())),
    (REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), '11111111111111111111111111111111', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
     '30000000000000000000000000000002', 'Sam', 'Looks good, added the API skeleton.', DATEADD(MINUTE, -20, SYSUTCDATETIME())),
    (REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), '11111111111111111111111111111111', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
     '30000000000000000000000000000001', 'Jane', 'DB contracts are locked, building read path next.', DATEADD(MINUTE, -10, SYSUTCDATETIME()));
END
GO

IF NOT EXISTS (SELECT 1 FROM dsc.dsc_Comment WHERE TenantID = '22222222222222222222222222222222')
BEGIN
    INSERT INTO dsc.dsc_Comment (CommentID, TenantID, ThreadID, AuthorMemberID, AuthorName, Body, CreatedUtc)
    VALUES
    (REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), '22222222222222222222222222222222', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
     '40000000000000000000000000000001', 'Priya', 'Tenant B thread — should never appear under tenant A.', DATEADD(MINUTE, -15, SYSUTCDATETIME())),
    (REPLACE(CONVERT(varchar(36), NEWID()), '-', ''), '22222222222222222222222222222222', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
     '40000000000000000000000000000001', 'Priya', 'Used purely for the negative isolation test.', DATEADD(MINUTE, -5, SYSUTCDATETIME()));
END
GO
