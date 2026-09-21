-- Discussion Thread PoC — db/init.sql
-- Idempotent: safe to run twice. Creates DB, schema, table, procedures, seed data.

IF DB_ID('DiscussionPoC') IS NULL
BEGIN
    CREATE DATABASE DiscussionPoC;
END
GO

USE DiscussionPoC;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dsc')
BEGIN
    EXEC('CREATE SCHEMA dsc');
END
GO

IF OBJECT_ID('dsc.Comments', 'U') IS NULL
BEGIN
    CREATE TABLE dsc.Comments (
        TenantId       UNIQUEIDENTIFIER NOT NULL,
        CommentId      UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        ThreadId       UNIQUEIDENTIFIER NOT NULL,
        AuthorMemberId UNIQUEIDENTIFIER NOT NULL,
        AuthorName     NVARCHAR(100)    NOT NULL,
        Body           NVARCHAR(MAX)    NOT NULL,
        IsDeleted      BIT              NOT NULL DEFAULT 0,
        CreatedUtc     DATETIME2        NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Comments PRIMARY KEY (TenantId, CommentId)
    );
    CREATE INDEX IX_Comments_Thread ON dsc.Comments (TenantId, ThreadId, CreatedUtc);
END
GO

-- ---------------------------------------------------------------------
-- Stored procedures (signatures per section 1.3 of the plan)
-- ---------------------------------------------------------------------

CREATE OR ALTER PROCEDURE dsc.Comments_GetByThread_JSON
    @TenantId UNIQUEIDENTIFIER, @ThreadId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT CommentId AS commentId, ThreadId AS threadId, TenantId AS tenantId,
           AuthorMemberId AS authorMemberId, AuthorName AS authorName,
           Body AS body, CreatedUtc AS createdUtc
    FROM dsc.Comments
    WHERE TenantId = @TenantId AND ThreadId = @ThreadId AND IsDeleted = 0
    ORDER BY CreatedUtc
    FOR JSON PATH;
END;
GO

CREATE OR ALTER PROCEDURE dsc.Comments_Create_JSON
    @TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER,
    @ThreadId UNIQUEIDENTIFIER, @Input NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Input) <> 1 THROW 50001, 'Input is not valid JSON.', 1;
    DECLARE @Body NVARCHAR(MAX) = JSON_VALUE(@Input, '$.body');
    IF @Body IS NULL OR LTRIM(RTRIM(@Body)) = '' THROW 50002, 'body is required.', 1;
    DECLARE @Name NVARCHAR(100) = ISNULL(JSON_VALUE(@Input, '$.authorName'), 'Member');
    DECLARE @Id UNIQUEIDENTIFIER = NEWID();

    INSERT INTO dsc.Comments (TenantId, CommentId, ThreadId, AuthorMemberId, AuthorName, Body)
    VALUES (@TenantId, @Id, @ThreadId, @MemberId, @Name, @Body);

    SELECT CommentId AS commentId, ThreadId AS threadId, TenantId AS tenantId,
           AuthorMemberId AS authorMemberId, AuthorName AS authorName,
           Body AS body, CreatedUtc AS createdUtc
    FROM dsc.Comments WHERE TenantId = @TenantId AND CommentId = @Id
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END;
GO

CREATE OR ALTER PROCEDURE dsc.Comments_Delete_JSON
    @TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER, @CommentId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dsc.Comments SET IsDeleted = 1
    WHERE TenantId = @TenantId AND CommentId = @CommentId AND IsDeleted = 0;
    SELECT @@ROWCOUNT AS deleted FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END;
GO

-- ---------------------------------------------------------------------
-- Seed data — two tenants, one thread each, so the negative isolation
-- test in Stage C has something to *not* return. Fixed, memorable GUIDs
-- so they can be typed straight into Swagger.
--   Tenant A: 11111111-1111-1111-1111-111111111111  Thread A: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
--   Tenant B: 22222222-2222-2222-2222-222222222222  Thread B: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
-- ---------------------------------------------------------------------

IF NOT EXISTS (SELECT 1 FROM dsc.Comments WHERE TenantId = '11111111-1111-1111-1111-111111111111')
BEGIN
    INSERT INTO dsc.Comments (TenantId, CommentId, ThreadId, AuthorMemberId, AuthorName, Body, CreatedUtc)
    VALUES
    ('11111111-1111-1111-1111-111111111111', NEWID(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     '30000000-0000-0000-0000-000000000001', 'Jane', 'Kicking off the thread — welcome!', DATEADD(MINUTE, -30, SYSUTCDATETIME())),
    ('11111111-1111-1111-1111-111111111111', NEWID(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     '30000000-0000-0000-0000-000000000002', 'Sam', 'Looks good, added the API skeleton.', DATEADD(MINUTE, -20, SYSUTCDATETIME())),
    ('11111111-1111-1111-1111-111111111111', NEWID(), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     '30000000-0000-0000-0000-000000000001', 'Jane', 'DB contracts are locked, building read path next.', DATEADD(MINUTE, -10, SYSUTCDATETIME()));
END
GO

IF NOT EXISTS (SELECT 1 FROM dsc.Comments WHERE TenantId = '22222222-2222-2222-2222-222222222222')
BEGIN
    INSERT INTO dsc.Comments (TenantId, CommentId, ThreadId, AuthorMemberId, AuthorName, Body, CreatedUtc)
    VALUES
    ('22222222-2222-2222-2222-222222222222', NEWID(), 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     '40000000-0000-0000-0000-000000000001', 'Priya', 'Tenant B thread — should never appear under tenant A.', DATEADD(MINUTE, -15, SYSUTCDATETIME())),
    ('22222222-2222-2222-2222-222222222222', NEWID(), 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     '40000000-0000-0000-0000-000000000001', 'Priya', 'Used purely for the negative isolation test.', DATEADD(MINUTE, -5, SYSUTCDATETIME()));
END
GO
