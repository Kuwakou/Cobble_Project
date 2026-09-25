-- 100: Discussion Thread schema (Week 13 proof of concept).
-- Lives in its own schema 'dsc' so the module boundary is visible in the database itself,
-- but in the SAME database and SAME container - the syllabus allows exactly one SQL container.
--
-- Tenancy rule (identical to dbo): every table carries TenantId UNIQUEIDENTIFIER NOT NULL as the
-- leading key column, and the child references its parent by the composite (TenantId, ThreadId),
-- so a comment can never attach to a thread in another tenant - the engine enforces it.
--
-- Ownership rule: dsc_ stores only a MemberId reference plus a denormalised display name.
-- It does NOT foreign-key to dbo.Member - member profile is owned by the membership context.
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
SET NOCOUNT ON;
GO

-- AUTHORIZATION dbo keeps dsc objects and dbo objects under one owner, so ownership chaining
-- lets a dsc procedure read dsc tables and call dbo.fn_Json* while the API login is denied
-- every direct table verb.
IF SCHEMA_ID('dsc') IS NULL
    EXEC ('CREATE SCHEMA dsc AUTHORIZATION dbo;');
GO

-------------------------------------------------------------------------------
-- Thread (aggregate root). The PoC uses one seeded thread per tenant.
-------------------------------------------------------------------------------
IF OBJECT_ID('dsc.Thread', 'U') IS NULL
BEGIN
    CREATE TABLE dsc.Thread
    (
        TenantId  UNIQUEIDENTIFIER NOT NULL,
        ThreadId  UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Thread_Id DEFAULT NEWSEQUENTIALID(),
        Title     NVARCHAR(200)    NOT NULL,
        CreatedAt DATETIME2(0)     NOT NULL CONSTRAINT DF_Thread_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Thread PRIMARY KEY CLUSTERED (TenantId, ThreadId)
    );
END
GO

-------------------------------------------------------------------------------
-- Comment (child of Thread).
-- IsDeleted = soft delete: rows are never physically removed, so the moderation/audit trail
-- survives. Every read filters IsDeleted = 0.
-------------------------------------------------------------------------------
IF OBJECT_ID('dsc.Comment', 'U') IS NULL
BEGIN
    CREATE TABLE dsc.Comment
    (
        TenantId          UNIQUEIDENTIFIER NOT NULL,
        CommentId         UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Comment_Id DEFAULT NEWSEQUENTIALID(),
        ThreadId          UNIQUEIDENTIFIER NOT NULL,
        AuthorMemberId    UNIQUEIDENTIFIER NOT NULL,   -- soft reference to the membership context
        AuthorDisplayName NVARCHAR(100)    NOT NULL,   -- denormalised snapshot; dsc_ does not own profiles
        Body              NVARCHAR(2000)   NOT NULL,
        IsDeleted         BIT              NOT NULL CONSTRAINT DF_Comment_IsDeleted DEFAULT 0,
        DeletedAt         DATETIME2(0)     NULL,
        CreatedAt         DATETIME2(0)     NOT NULL CONSTRAINT DF_Comment_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Comment PRIMARY KEY CLUSTERED (TenantId, CommentId),
        CONSTRAINT FK_Comment_Thread FOREIGN KEY (TenantId, ThreadId)
            REFERENCES dsc.Thread (TenantId, ThreadId) ON DELETE CASCADE,
        CONSTRAINT CK_Comment_Body CHECK (LEN(LTRIM(RTRIM(Body))) > 0),
        CONSTRAINT CK_Comment_Deleted CHECK ((IsDeleted = 0 AND DeletedAt IS NULL)
                                          OR (IsDeleted = 1 AND DeletedAt IS NOT NULL))
    );
    -- Covers the only read the PoC performs: one thread's live comments in posting order.
    CREATE INDEX IX_Comment_Thread ON dsc.Comment (TenantId, ThreadId, CreatedAt)
        INCLUDE (AuthorMemberId, AuthorDisplayName, Body) WHERE IsDeleted = 0;
END
GO

-------------------------------------------------------------------------------
-- Reply support: a comment may optionally point at another comment in the
-- same thread as its parent. NULL = top-level comment. Only one level of
-- nesting is supported (a reply's own ParentCommentId must be NULL) - that
-- rule is enforced in dsc.usp_Comment_Add, not here, since a CHECK
-- constraint can't see other rows.
-- Idempotent, same guarded-ALTER pattern as the rest of this file, so
-- re-running init.sql after the column already exists is a no-op.
-------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dsc.Comment') AND name = 'ParentCommentId'
)
BEGIN
    ALTER TABLE dsc.Comment ADD ParentCommentId UNIQUEIDENTIFIER NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Comment_ParentComment')
BEGIN
    ALTER TABLE dsc.Comment
        ADD CONSTRAINT FK_Comment_ParentComment FOREIGN KEY (TenantId, ParentCommentId)
            REFERENCES dsc.Comment (TenantId, CommentId);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Comment_Parent' AND object_id = OBJECT_ID('dsc.Comment')
)
BEGIN
    CREATE INDEX IX_Comment_Parent ON dsc.Comment (TenantId, ParentCommentId)
        WHERE ParentCommentId IS NOT NULL;
END
GO

-------------------------------------------------------------------------------
-- Guard: every table in dsc MUST have TenantId UNIQUEIDENTIFIER NOT NULL.
-- Mirrors the dbo guard in 010-tables.sql; fails the deployment if someone forgets.
-------------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.tables t
    WHERE t.schema_id = SCHEMA_ID('dsc')
      AND NOT EXISTS (
          SELECT 1 FROM sys.columns c
          JOIN sys.types ty ON ty.user_type_id = c.user_type_id
          WHERE c.object_id = t.object_id AND c.name = 'TenantId'
            AND ty.name = 'uniqueidentifier' AND c.is_nullable = 0))
BEGIN
    THROW 50000, 'Tenancy guard: a dsc table is missing TenantId UNIQUEIDENTIFIER NOT NULL.', 1;
END
GO
