-- Discussion Thread PoC — db/init.sql
-- Idempotent: safe to run twice. Creates DB, schema, table, procedures, seed data.
--
-- Replies: one flat level only. ParentCommentId = NULL means top-level; a non-NULL
-- ParentCommentId means it's a reply. Comments_Create_JSON rejects a reply whose parent
-- is itself a reply, so replies never nest past one level.

IF DB_ID('DiscussionPoC') IS NULL
BEGIN
    CREATE DATABASE DiscussionPoC;
END
GO

USE DiscussionPoC;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
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

-- Added for replies. Guarded so this applies cleanly to a DB that already exists
-- from before replies were added, as well as to a brand-new one.
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dsc.Comments') AND name = 'ParentCommentId'
)
BEGIN
    ALTER TABLE dsc.Comments ADD ParentCommentId UNIQUEIDENTIFIER NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Comments_ParentComment')
BEGIN
    ALTER TABLE dsc.Comments
        ADD CONSTRAINT FK_Comments_ParentComment FOREIGN KEY (TenantId, ParentCommentId)
            REFERENCES dsc.Comments (TenantId, CommentId);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_Comments_Parent' AND object_id = OBJECT_ID('dsc.Comments')
)
BEGIN
    CREATE INDEX IX_Comments_Parent ON dsc.Comments (TenantId, ParentCommentId)
        WHERE ParentCommentId IS NOT NULL;
END
GO

-- ---------------------------------------------------------------------
-- Votes. One row per (tenant, comment, member): a member holds at most ONE
-- vote on a comment, so the primary key itself prevents ballot stuffing -
-- voting again replaces the existing row rather than adding another.
-- Value is +1 (like) or -1 (dislike); clearing a vote deletes the row.
-- ---------------------------------------------------------------------
-- Target for the self-vote foreign key below. (TenantId, CommentId) is already
-- the primary key of dsc.Comments, so adding AuthorMemberId is still unique -
-- this index exists purely to let a FK reference the author column.
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'UX_Comments_Author' AND object_id = OBJECT_ID('dsc.Comments')
)
BEGIN
    CREATE UNIQUE INDEX UX_Comments_Author
        ON dsc.Comments (TenantId, CommentId, AuthorMemberId);
END
GO

IF OBJECT_ID('dsc.CommentVotes', 'U') IS NULL
BEGIN
    CREATE TABLE dsc.CommentVotes (
        TenantId              UNIQUEIDENTIFIER NOT NULL,
        CommentId             UNIQUEIDENTIFIER NOT NULL,
        MemberId              UNIQUEIDENTIFIER NOT NULL,
        -- The author of the comment being voted on, copied here ONLY so the
        -- two constraints below can compare it against the voter. The FK
        -- guarantees this really is that comment's author - it cannot be
        -- faked - and the CHECK then guarantees the voter is someone else.
        CommentAuthorMemberId UNIQUEIDENTIFIER NOT NULL,
        Value                 SMALLINT         NOT NULL,
        CreatedUtc            DATETIME2        NOT NULL CONSTRAINT DF_CommentVotes_CreatedUtc DEFAULT SYSUTCDATETIME(),
        UpdatedUtc            DATETIME2        NOT NULL CONSTRAINT DF_CommentVotes_UpdatedUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_CommentVotes PRIMARY KEY (TenantId, CommentId, MemberId),
        CONSTRAINT CK_CommentVotes_Value CHECK (Value IN (-1, 1)),
        -- Composite FK: a vote can only ever reference a comment in the SAME
        -- tenant, AND the author recorded must be that comment's real author.
        -- Cross-tenant or forged-author votes are refused by the engine (547).
        CONSTRAINT FK_CommentVotes_CommentAuthor
            FOREIGN KEY (TenantId, CommentId, CommentAuthorMemberId)
            REFERENCES dsc.Comments (TenantId, CommentId, AuthorMemberId),
        -- No self-voting, enforced by the engine rather than by procedure
        -- logic: there is no INSERT or UPDATE, from any client, that can put
        -- a member's vote on their own comment.
        CONSTRAINT CK_CommentVotes_NoSelfVote CHECK (MemberId <> CommentAuthorMemberId)
    );
    -- Covers the karma rollup, which aggregates every vote a member received.
    CREATE INDEX IX_CommentVotes_Comment ON dsc.CommentVotes (TenantId, CommentId) INCLUDE (Value);
END
GO

-- Guarded upgrade for a database created before the no-self-vote constraints
-- existed: add the column, backfill it from the comment, drop any self-votes
-- that slipped in, then enforce.
IF COL_LENGTH('dsc.CommentVotes', 'CommentAuthorMemberId') IS NULL
BEGIN
    ALTER TABLE dsc.CommentVotes ADD CommentAuthorMemberId UNIQUEIDENTIFIER NULL;
END
GO

UPDATE v SET CommentAuthorMemberId = c.AuthorMemberId
FROM dsc.CommentVotes v
JOIN dsc.Comments c ON c.TenantId = v.TenantId AND c.CommentId = v.CommentId
WHERE v.CommentAuthorMemberId IS NULL;
GO

-- Any pre-existing self-vote must go, or the constraint cannot be trusted.
DELETE FROM dsc.CommentVotes WHERE MemberId = CommentAuthorMemberId;
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dsc.CommentVotes')
      AND name = 'CommentAuthorMemberId' AND is_nullable = 1
)
BEGIN
    ALTER TABLE dsc.CommentVotes ALTER COLUMN CommentAuthorMemberId UNIQUEIDENTIFIER NOT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_CommentVotes_CommentAuthor')
BEGIN
    ALTER TABLE dsc.CommentVotes
        ADD CONSTRAINT FK_CommentVotes_CommentAuthor
            FOREIGN KEY (TenantId, CommentId, CommentAuthorMemberId)
            REFERENCES dsc.Comments (TenantId, CommentId, AuthorMemberId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_CommentVotes_NoSelfVote')
BEGIN
    ALTER TABLE dsc.CommentVotes
        ADD CONSTRAINT CK_CommentVotes_NoSelfVote CHECK (MemberId <> CommentAuthorMemberId);
END
GO

-- The old two-column FK is now subsumed by FK_CommentVotes_CommentAuthor,
-- which enforces the same tenant + comment pairing plus the author.
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_CommentVotes_Comment')
BEGIN
    ALTER TABLE dsc.CommentVotes DROP CONSTRAINT FK_CommentVotes_Comment;
END
GO

-- ---------------------------------------------------------------------
-- Karma. A member's karma is the net score of every vote received on the
-- comments they authored: likes received minus dislikes received. Votes a
-- member casts do not change their own karma.
--
-- This is a VIEW, not a stored counter, so karma can never drift out of
-- step with the votes it is derived from. If the thread ever grows past a
-- few thousand comments, swap it for a summary table maintained by the
-- vote procedure - the contract below does not change.
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW dsc.vw_MemberKarma
AS
SELECT c.TenantId,
       c.AuthorMemberId                                           AS MemberId,
       MAX(c.AuthorName)                                          AS MemberName,
       COUNT(DISTINCT c.CommentId)                                AS CommentCount,
       ISNULL(SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END), 0)   AS LikesReceived,
       ISNULL(SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END), 0)   AS DislikesReceived,
       ISNULL(SUM(v.Value), 0)                                    AS Karma
FROM dsc.Comments c
LEFT JOIN dsc.CommentVotes v
       ON v.TenantId = c.TenantId AND v.CommentId = c.CommentId
WHERE c.IsDeleted = 0
GROUP BY c.TenantId, c.AuthorMemberId;
GO

-- ---------------------------------------------------------------------
-- Stored procedures (signatures per section 1.3 of the plan)
-- ---------------------------------------------------------------------

-- @MemberId is OPTIONAL and defaults to NULL, so existing callers that pass
-- only two arguments keep working. When supplied, each comment also carries
-- myVote: the vote THIS member has cast on it (1, -1 or 0), which is what the
-- UI needs to show a button as already pressed.
CREATE OR ALTER PROCEDURE dsc.Comments_GetByThread_JSON
    @TenantId UNIQUEIDENTIFIER, @ThreadId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.CommentId AS commentId, c.ThreadId AS threadId, c.TenantId AS tenantId,
           c.AuthorMemberId AS authorMemberId, c.AuthorName AS authorName,
           c.Body AS body, c.ParentCommentId AS parentCommentId, c.CreatedUtc AS createdUtc,
           ISNULL(t.Likes, 0)    AS likes,
           ISNULL(t.Dislikes, 0) AS dislikes,
           ISNULL(t.Score, 0)    AS score,
           ISNULL(mv.Value, 0)   AS myVote,
           ISNULL(k.Karma, 0)    AS authorKarma
    FROM dsc.Comments c
    OUTER APPLY (
        SELECT SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END) AS Likes,
               SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END) AS Dislikes,
               SUM(v.Value)                                  AS Score
        FROM dsc.CommentVotes v
        WHERE v.TenantId = c.TenantId AND v.CommentId = c.CommentId
    ) t
    LEFT JOIN dsc.CommentVotes mv
           ON mv.TenantId = c.TenantId AND mv.CommentId = c.CommentId AND mv.MemberId = @MemberId
    LEFT JOIN dsc.vw_MemberKarma k
           ON k.TenantId = c.TenantId AND k.MemberId = c.AuthorMemberId
    WHERE c.TenantId = @TenantId AND c.ThreadId = @ThreadId AND c.IsDeleted = 0
    ORDER BY c.CreatedUtc
    FOR JSON PATH, INCLUDE_NULL_VALUES;
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
    DECLARE @ParentCommentId UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER, JSON_VALUE(@Input, '$.parentCommentId'));

    IF @ParentCommentId IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dsc.Comments
        WHERE TenantId = @TenantId AND ThreadId = @ThreadId AND CommentId = @ParentCommentId
          AND IsDeleted = 0 AND ParentCommentId IS NULL
    )
        THROW 50003, 'parentCommentId not found, or is itself a reply.', 1;

    DECLARE @Id UNIQUEIDENTIFIER = NEWID();

    INSERT INTO dsc.Comments (TenantId, CommentId, ThreadId, AuthorMemberId, AuthorName, Body, ParentCommentId)
    VALUES (@TenantId, @Id, @ThreadId, @MemberId, @Name, @Body, @ParentCommentId);

    SELECT CommentId AS commentId, ThreadId AS threadId, TenantId AS tenantId,
           AuthorMemberId AS authorMemberId, AuthorName AS authorName,
           Body AS body, ParentCommentId AS parentCommentId, CreatedUtc AS createdUtc
    FROM dsc.Comments WHERE TenantId = @TenantId AND CommentId = @Id
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;
END;
GO

CREATE OR ALTER PROCEDURE dsc.Comments_Delete_JSON
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @CommentId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Owner UNIQUEIDENTIFIER = (
        SELECT AuthorMemberId
        FROM dsc.Comments
        WHERE TenantId = @TenantId
          AND CommentId = @CommentId
          AND IsDeleted = 0
    );

    IF @Owner IS NULL
        THROW 50004, 'Comment not found.', 1;

    IF @Owner <> @MemberId
        THROW 50005, 'Only the author can delete their comment.', 1;

    UPDATE dsc.Comments
    SET IsDeleted = 1
    WHERE TenantId = @TenantId
      AND CommentId = @CommentId
      AND IsDeleted = 0;

    SELECT @@ROWCOUNT AS deleted
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END;
GO

CREATE OR ALTER PROCEDURE dsc.Comments_Update_JSON
    @TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER,
    @ThreadId UNIQUEIDENTIFIER, @CommentId UNIQUEIDENTIFIER, @Input NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@Input) <> 1 THROW 50001, 'Input is not valid JSON.', 1;
    DECLARE @Body NVARCHAR(MAX) = JSON_VALUE(@Input, '$.body');
    IF @Body IS NULL OR LTRIM(RTRIM(@Body)) = '' THROW 50002, 'body is required.', 1;

    DECLARE @Owner UNIQUEIDENTIFIER = (
        SELECT AuthorMemberId FROM dsc.Comments
        WHERE TenantId = @TenantId AND ThreadId = @ThreadId AND CommentId = @CommentId AND IsDeleted = 0
    );

    IF @Owner IS NULL THROW 50004, 'Comment not found.', 1;
    IF @Owner <> @MemberId THROW 50005, 'Only the author can update their comment.', 1;

    UPDATE dsc.Comments SET Body = @Body
    WHERE TenantId = @TenantId AND ThreadId = @ThreadId AND CommentId = @CommentId AND IsDeleted = 0;

    SELECT CommentId AS commentId, ThreadId AS threadId, TenantId AS tenantId,
           AuthorMemberId AS authorMemberId, AuthorName AS authorName,
           Body AS body, ParentCommentId AS parentCommentId, CreatedUtc AS createdUtc
    FROM dsc.Comments WHERE TenantId = @TenantId AND CommentId = @CommentId
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;
END;
GO

-- ---------------------------------------------------------------------
-- dsc.CommentVote_Set_JSON
-- in : @TenantId, @MemberId (both from the caller's identity, never the body),
--      @CommentId, @Input = { "value": 1 | -1 | 0 }
--        1 = like, -1 = dislike, 0 = clear my vote (pressing the same
--        button again is a toggle-off, which the API sends as 0).
-- out: the comment's updated tallies + the author's new karma
-- err: 50020 bad value | 50004 comment not found | 50021 self-vote
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.CommentVote_Set_JSON
    @TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER,
    @CommentId UNIQUEIDENTIFIER, @Input NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF ISJSON(@Input) <> 1 THROW 50001, 'Input is not valid JSON.', 1;

    DECLARE @Value INT = TRY_CONVERT(INT, JSON_VALUE(@Input, '$.value'));
    IF @Value IS NULL OR @Value NOT IN (-1, 0, 1)
        THROW 50020, 'value must be 1 (like), -1 (dislike) or 0 (clear).', 1;

    -- Tenant fence: a comment in another tenant is simply not found, so a
    -- caller cannot vote on - or confirm the existence of - foreign content.
    DECLARE @Author UNIQUEIDENTIFIER = (
        SELECT AuthorMemberId FROM dsc.Comments
        WHERE TenantId = @TenantId AND CommentId = @CommentId AND IsDeleted = 0);

    IF @Author IS NULL THROW 50004, 'Comment not found.', 1;

    -- Karma has to mean something: you cannot inflate your own.
    IF @Author = @MemberId
        THROW 50021, 'You cannot vote on your own comment.', 1;

    IF @Value = 0
        DELETE FROM dsc.CommentVotes
        WHERE TenantId = @TenantId AND CommentId = @CommentId AND MemberId = @MemberId;
    ELSE
    BEGIN
        -- Upsert: the PK guarantees one vote per member per comment, so
        -- switching from like to dislike updates in place rather than
        -- stacking a second vote.
        UPDATE dsc.CommentVotes
        SET Value = @Value, UpdatedUtc = SYSUTCDATETIME()
        WHERE TenantId = @TenantId AND CommentId = @CommentId AND MemberId = @MemberId;

        IF @@ROWCOUNT = 0
            INSERT INTO dsc.CommentVotes (TenantId, CommentId, MemberId, CommentAuthorMemberId, Value)
            VALUES (@TenantId, @CommentId, @MemberId, @Author, @Value);
    END

    SELECT c.CommentId AS commentId, c.AuthorMemberId AS authorMemberId,
           ISNULL(t.Likes, 0)    AS likes,
           ISNULL(t.Dislikes, 0) AS dislikes,
           ISNULL(t.Score, 0)    AS score,
           ISNULL(mv.Value, 0)   AS myVote,
           ISNULL(k.Karma, 0)    AS authorKarma
    FROM dsc.Comments c
    OUTER APPLY (
        SELECT SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END) AS Likes,
               SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END) AS Dislikes,
               SUM(v.Value)                                  AS Score
        FROM dsc.CommentVotes v
        WHERE v.TenantId = c.TenantId AND v.CommentId = c.CommentId
    ) t
    LEFT JOIN dsc.CommentVotes mv
           ON mv.TenantId = c.TenantId AND mv.CommentId = c.CommentId AND mv.MemberId = @MemberId
    LEFT JOIN dsc.vw_MemberKarma k
           ON k.TenantId = c.TenantId AND k.MemberId = c.AuthorMemberId
    WHERE c.TenantId = @TenantId AND c.CommentId = @CommentId
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END;
GO

-- ---------------------------------------------------------------------
-- dsc.MemberKarma_Get_JSON - one member's karma card.
-- Returns a zero row rather than nothing for a member who has not posted,
-- so the API never has to special-case "no record yet".
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.MemberKarma_Get_JSON
    @TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @MemberId                        AS memberId,
           ISNULL(k.MemberName, N'Member')  AS memberName,
           ISNULL(k.CommentCount, 0)        AS commentCount,
           ISNULL(k.LikesReceived, 0)       AS likesReceived,
           ISNULL(k.DislikesReceived, 0)    AS dislikesReceived,
           ISNULL(k.Karma, 0)               AS karma
    FROM (SELECT 1 AS x) seed
    LEFT JOIN dsc.vw_MemberKarma k
           ON k.TenantId = @TenantId AND k.MemberId = @MemberId
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END;
GO

-- ---------------------------------------------------------------------
-- dsc.MemberKarma_List_JSON - the leaderboard for one tenant, best first.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.MemberKarma_List_JSON
    @TenantId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT MemberId         AS memberId,
           MemberName       AS memberName,
           CommentCount     AS commentCount,
           LikesReceived    AS likesReceived,
           DislikesReceived AS dislikesReceived,
           Karma            AS karma
    FROM dsc.vw_MemberKarma
    WHERE TenantId = @TenantId
    ORDER BY Karma DESC, MemberName
    FOR JSON PATH;
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

-- ---------------------------------------------------------------------
-- Seed votes, so karma is non-zero the first time the board is opened.
-- Members are referenced by the ids used in the comment seed above:
--   30000000-...0001 Jane   30000000-...0002 Sam   30000000-...0003 Alex
-- Nobody votes on their own comment - the procedure would refuse it, and
-- the seed must reflect the same rule.
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dsc.CommentVotes)
BEGIN
    DECLARE @TenantA UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
    DECLARE @Jane UNIQUEIDENTIFIER = '30000000-0000-0000-0000-000000000001';
    DECLARE @Sam  UNIQUEIDENTIFIER = '30000000-0000-0000-0000-000000000002';
    DECLARE @Alex UNIQUEIDENTIFIER = '30000000-0000-0000-0000-000000000003';

    -- Sam and Alex both like Jane's opening comment.
    INSERT INTO dsc.CommentVotes (TenantId, CommentId, MemberId, CommentAuthorMemberId, Value)
    SELECT c.TenantId, c.CommentId, v.MemberId, c.AuthorMemberId, v.Value
    FROM dsc.Comments c
    CROSS JOIN (VALUES (@Sam, 1), (@Alex, 1)) v (MemberId, Value)
    WHERE c.TenantId = @TenantA AND c.AuthorMemberId = @Jane
      AND c.Body LIKE 'Kicking off%' AND c.IsDeleted = 0;

    -- Alex likes Sam's comment; Jane likes it too.
    INSERT INTO dsc.CommentVotes (TenantId, CommentId, MemberId, CommentAuthorMemberId, Value)
    SELECT c.TenantId, c.CommentId, v.MemberId, c.AuthorMemberId, v.Value
    FROM dsc.Comments c
    CROSS JOIN (VALUES (@Alex, 1), (@Jane, 1)) v (MemberId, Value)
    WHERE c.TenantId = @TenantA AND c.AuthorMemberId = @Sam
      AND c.Body LIKE 'Looks good%' AND c.IsDeleted = 0;

    -- One dislike, so the counters are visibly independent of each other.
    INSERT INTO dsc.CommentVotes (TenantId, CommentId, MemberId, CommentAuthorMemberId, Value)
    SELECT c.TenantId, c.CommentId, @Sam, c.AuthorMemberId, -1
    FROM dsc.Comments c
    WHERE c.TenantId = @TenantA AND c.AuthorMemberId = @Jane
      AND c.Body LIKE 'DB contracts%' AND c.IsDeleted = 0;
END
GO

DECLARE @Votes INT = (SELECT COUNT(*) FROM dsc.CommentVotes);
DECLARE @Members INT = (SELECT COUNT(*) FROM dsc.vw_MemberKarma);
PRINT CONCAT('dsc ready - votes: ', @Votes, ' | members with karma: ', @Members);
GO
