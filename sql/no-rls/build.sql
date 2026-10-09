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
   for local development; see ../rls/build.sql for the isolation-tested path.

   Votes/karma/reports below are a char(32)/SESSION_CONTEXT port of the same
   features your team built on origin/main's sql/init/init.sql (UNIQUEIDENTIFIER,
   explicit @MemberId params) - same rules, same engine-level no-self-vote /
   no-self-report constraints, different identity plumbing. */
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

-- FK target for votes/reports below: (CommentID, AuthorMemberID) is unique
-- because CommentID alone is already the primary key, so this index exists
-- purely so a composite FK can pin "this really is that comment's author".
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_dsc_Comment_Author' AND object_id = OBJECT_ID('dsc.dsc_Comment'))
    CREATE UNIQUE INDEX UX_dsc_Comment_Author ON dsc.dsc_Comment (CommentID, AuthorMemberID);
GO

-------------------------------------------------------------------------------
-- Votes. One row per (comment, member): a member holds at most ONE vote on a
-- comment, so the primary key itself prevents ballot stuffing - voting again
-- replaces the row rather than adding another. Value is +1 (like) or -1
-- (dislike); clearing a vote deletes the row. No self-voting is enforced by
-- the engine (a CHECK constraint), not by procedure logic - no client, and no
-- future procedure, can get around it.
-------------------------------------------------------------------------------
IF OBJECT_ID('dsc.dsc_CommentVote', 'U') IS NULL
CREATE TABLE dsc.dsc_CommentVote (
    CommentID             char(32)  NOT NULL,
    MemberID              char(32)  NOT NULL,
    CommentAuthorMemberID char(32)  NOT NULL,
    Value                 smallint  NOT NULL,
    CreatedUtc            datetime2(0) NOT NULL CONSTRAINT DF_dsc_CommentVote_Created DEFAULT sysutcdatetime(),
    UpdatedUtc            datetime2(0) NOT NULL CONSTRAINT DF_dsc_CommentVote_Updated DEFAULT sysutcdatetime(),
    CONSTRAINT PK_dsc_CommentVote PRIMARY KEY (CommentID, MemberID),
    CONSTRAINT CK_dsc_CommentVote_Value CHECK (Value IN (-1, 1)),
    CONSTRAINT FK_dsc_CommentVote_CommentAuthor FOREIGN KEY (CommentID, CommentAuthorMemberID)
        REFERENCES dsc.dsc_Comment (CommentID, AuthorMemberID),
    CONSTRAINT CK_dsc_CommentVote_NoSelfVote CHECK (MemberID <> CommentAuthorMemberID)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_dsc_CommentVote_Comment' AND object_id = OBJECT_ID('dsc.dsc_CommentVote'))
    CREATE INDEX IX_dsc_CommentVote_Comment ON dsc.dsc_CommentVote (CommentID) INCLUDE (Value);
GO

-------------------------------------------------------------------------------
-- Reports. Same shape as votes and for the same reason - the rules that
-- matter (no self-report, one flag per member per comment) are enforced by
-- the engine. Rows are never deleted, so the moderation queue keeps its
-- audit trail even once a flagged comment is removed.
-------------------------------------------------------------------------------
IF OBJECT_ID('dsc.dsc_CommentReport', 'U') IS NULL
CREATE TABLE dsc.dsc_CommentReport (
    CommentID             char(32)      NOT NULL,
    ReporterMemberID      char(32)      NOT NULL,
    CommentAuthorMemberID char(32)      NOT NULL,
    Reason                nvarchar(500) NOT NULL,
    CreatedUtc            datetime2(0)  NOT NULL CONSTRAINT DF_dsc_CommentReport_Created DEFAULT sysutcdatetime(),
    UpdatedUtc            datetime2(0)  NOT NULL CONSTRAINT DF_dsc_CommentReport_Updated DEFAULT sysutcdatetime(),
    CONSTRAINT PK_dsc_CommentReport PRIMARY KEY (CommentID, ReporterMemberID),
    CONSTRAINT FK_dsc_CommentReport_CommentAuthor FOREIGN KEY (CommentID, CommentAuthorMemberID)
        REFERENCES dsc.dsc_Comment (CommentID, AuthorMemberID),
    CONSTRAINT CK_dsc_CommentReport_NoSelfReport CHECK (ReporterMemberID <> CommentAuthorMemberID)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_dsc_CommentReport_Comment' AND object_id = OBJECT_ID('dsc.dsc_CommentReport'))
    CREATE INDEX IX_dsc_CommentReport_Comment ON dsc.dsc_CommentReport (CommentID);
GO

-------------------------------------------------------------------------------
-- Karma. Net score of every vote received on the comments a member authored
-- (likes minus dislikes). A VIEW, not a stored counter, so it can never drift
-- out of step with the votes it's derived from.
-------------------------------------------------------------------------------
CREATE OR ALTER VIEW dsc.vw_dsc_MemberKarma
AS
SELECT c.TenantID,
       c.AuthorMemberID                                         AS MemberID,
       MAX(c.AuthorName)                                        AS MemberName,
       COUNT(DISTINCT c.CommentID)                               AS CommentCount,
       ISNULL(SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END), 0)  AS LikesReceived,
       ISNULL(SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END), 0)  AS DislikesReceived,
       ISNULL(SUM(v.Value), 0)                                   AS Karma
FROM dsc.dsc_Comment c
LEFT JOIN dsc.dsc_CommentVote v ON v.CommentID = c.CommentID
WHERE c.IsDeleted = 0
GROUP BY c.TenantID, c.AuthorMemberID;
GO

-------------------------------------------------------------------------------
-- dsc.dsc_Comment_CRUD_JSON
-- @Action: SELECT | INSERT | DELETE
--   SELECT @Payload = { "threadId": "..." }
--   INSERT @Payload = { "threadId", "body", "authorName", "parentCommentId" }
--   DELETE @Payload = { "commentId": "..." }
-- SELECT's rows now carry likes/dislikes/score/myVote/authorKarma, the same
-- fields origin/main's enriched Comments_GetByThread_JSON added.
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

        SELECT c.CommentID       AS commentId,
               c.ThreadID        AS threadId,
               c.TenantID        AS tenantId,
               c.AuthorMemberID  AS authorMemberId,
               c.AuthorName      AS authorName,
               c.Body            AS body,
               c.ParentCommentID AS parentCommentId,
               c.CreatedUtc      AS createdUtc,
               ISNULL(t.Likes, 0)    AS likes,
               ISNULL(t.Dislikes, 0) AS dislikes,
               ISNULL(t.Score, 0)    AS score,
               ISNULL(mv.Value, 0)   AS myVote,
               ISNULL(k.Karma, 0)    AS authorKarma
        FROM dsc.dsc_Comment c
        OUTER APPLY (
            SELECT SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END) AS Likes,
                   SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END) AS Dislikes,
                   SUM(v.Value)                                  AS Score
            FROM dsc.dsc_CommentVote v WHERE v.CommentID = c.CommentID
        ) t
        LEFT JOIN dsc.dsc_CommentVote mv ON mv.CommentID = c.CommentID AND mv.MemberID = @MemberID
        LEFT JOIN dsc.vw_dsc_MemberKarma k ON k.TenantID = c.TenantID AND k.MemberID = c.AuthorMemberID
        WHERE c.TenantID = @TenantID AND c.ThreadID = @ThreadID AND c.IsDeleted = 0
        ORDER BY c.CreatedUtc
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
               CreatedUtc      AS createdUtc,
               0 AS likes, 0 AS dislikes, 0 AS score, 0 AS myVote, 0 AS authorKarma
        FROM dsc.dsc_Comment
        WHERE CommentID = @NewID
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;
    END
    ELSE IF @Action = 'DELETE'
    BEGIN
        DECLARE @DelThreadID char(32) = JSON_VALUE(@Payload, '$.threadId');
        DECLARE @DelCommentID char(32) = JSON_VALUE(@Payload, '$.commentId');
        DECLARE @Owner char(32) = (
            SELECT AuthorMemberID FROM dsc.dsc_Comment
            WHERE TenantID = @TenantID
                AND ThreadID = @DelThreadID
                AND CommentID = @DelCommentID
                AND IsDeleted = 0);

        IF @Owner IS NULL
            THROW 50005, 'DSC_COMMENT_NOT_FOUND', 1;
        IF @Owner <> @MemberID
            THROW 50006, 'DSC_COMMENT_FORBIDDEN', 1;

        UPDATE dsc.dsc_Comment
        SET IsDeleted = 1, UpdatedUtc = sysutcdatetime()
        WHERE TenantID = @TenantID
            AND ThreadID = @DelThreadID
            AND CommentID = @DelCommentID;

        SELECT @DelCommentID AS commentId, CAST(1 AS bit) AS deleted
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
    END
    ELSE
        THROW 50099, 'DSC_ACTION_INVALID', 1;
END
GO

-------------------------------------------------------------------------------
-- dsc.dsc_CommentVote_CRUD_JSON
-- @Action: SET
--   @Payload = { "threadId", "commentId", "value": 1 | -1 | 0 }
--   1 = like, -1 = dislike, 0 = clear (the UI sends 0 for a toggle-off).
-- threadId is checked against the comment's real thread, not just accepted
-- and ignored - a comment can't be voted on through the wrong thread's URL.
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.dsc_CommentVote_CRUD_JSON
    @Action  varchar(12),
    @Payload nvarchar(max) = N'{}'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @TenantID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'TenantID'));
    DECLARE @MemberID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'MemberID'));
    IF @TenantID IS NULL OR @MemberID IS NULL
        THROW 50001, 'DSC_CONTEXT_REQUIRED', 1;

    IF @Action <> 'SET'
        THROW 50099, 'DSC_ACTION_INVALID', 1;

    DECLARE @ThreadID  char(32) = JSON_VALUE(@Payload, '$.threadId');
    DECLARE @CommentID char(32) = JSON_VALUE(@Payload, '$.commentId');
    DECLARE @Value INT = TRY_CONVERT(INT, JSON_VALUE(@Payload, '$.value'));
    IF @Value IS NULL OR @Value NOT IN (-1, 0, 1)
        THROW 50020, 'DSC_VOTE_VALUE_INVALID', 1;

    DECLARE @Author char(32) = (
        SELECT AuthorMemberID FROM dsc.dsc_Comment
        WHERE TenantID = @TenantID AND ThreadID = @ThreadID AND CommentID = @CommentID AND IsDeleted = 0);
    IF @Author IS NULL
        THROW 50005, 'DSC_COMMENT_NOT_FOUND', 1;
    IF @Author = @MemberID
        THROW 50021, 'DSC_SELF_VOTE', 1;

    IF @Value = 0
        DELETE FROM dsc.dsc_CommentVote WHERE CommentID = @CommentID AND MemberID = @MemberID;
    ELSE
    BEGIN
        UPDATE dsc.dsc_CommentVote
        SET Value = @Value, UpdatedUtc = sysutcdatetime()
        WHERE CommentID = @CommentID AND MemberID = @MemberID;

        IF @@ROWCOUNT = 0
            INSERT INTO dsc.dsc_CommentVote (CommentID, MemberID, CommentAuthorMemberID, Value)
            VALUES (@CommentID, @MemberID, @Author, @Value);
    END

    SELECT c.CommentID AS commentId, c.AuthorMemberID AS authorMemberId,
           ISNULL(t.Likes, 0)    AS likes,
           ISNULL(t.Dislikes, 0) AS dislikes,
           ISNULL(t.Score, 0)    AS score,
           ISNULL(mv.Value, 0)   AS myVote,
           ISNULL(k.Karma, 0)    AS authorKarma
    FROM dsc.dsc_Comment c
    OUTER APPLY (
        SELECT SUM(CASE WHEN v.Value =  1 THEN 1 ELSE 0 END) AS Likes,
               SUM(CASE WHEN v.Value = -1 THEN 1 ELSE 0 END) AS Dislikes,
               SUM(v.Value)                                  AS Score
        FROM dsc.dsc_CommentVote v WHERE v.CommentID = c.CommentID
    ) t
    LEFT JOIN dsc.dsc_CommentVote mv ON mv.CommentID = c.CommentID AND mv.MemberID = @MemberID
    LEFT JOIN dsc.vw_dsc_MemberKarma k ON k.TenantID = c.TenantID AND k.MemberID = c.AuthorMemberID
    WHERE c.CommentID = @CommentID
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END
GO

-------------------------------------------------------------------------------
-- dsc.dsc_CommentReport_CRUD_JSON
-- @Action: SET  -> flag/re-flag a comment: { "threadId", "commentId", "reason" }
-- @Action: LIST -> the moderation queue (no payload needed)
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.dsc_CommentReport_CRUD_JSON
    @Action  varchar(12),
    @Payload nvarchar(max) = N'{}'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @TenantID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'TenantID'));
    DECLARE @MemberID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'MemberID'));
    IF @TenantID IS NULL OR @MemberID IS NULL
        THROW 50001, 'DSC_CONTEXT_REQUIRED', 1;

    IF @Action = 'SET'
    BEGIN
        DECLARE @ThreadID  char(32) = JSON_VALUE(@Payload, '$.threadId');
        DECLARE @CommentID char(32) = JSON_VALUE(@Payload, '$.commentId');
        DECLARE @ReasonRaw nvarchar(max) = LTRIM(RTRIM(JSON_VALUE(@Payload, '$.reason')));
        IF @ReasonRaw IS NULL OR @ReasonRaw = N''
            THROW 50031, 'DSC_REPORT_REASON_REQUIRED', 1;
        IF LEN(@ReasonRaw) > 500
            THROW 50032, 'DSC_REPORT_REASON_TOO_LONG', 1;
        DECLARE @Reason nvarchar(500) = @ReasonRaw;

        DECLARE @Author char(32) = (
            SELECT AuthorMemberID FROM dsc.dsc_Comment
            WHERE TenantID = @TenantID AND ThreadID = @ThreadID AND CommentID = @CommentID AND IsDeleted = 0);
        IF @Author IS NULL
            THROW 50005, 'DSC_COMMENT_NOT_FOUND', 1;
        IF @Author = @MemberID
            THROW 50030, 'DSC_SELF_REPORT', 1;

        UPDATE dsc.dsc_CommentReport
        SET Reason = @Reason, UpdatedUtc = sysutcdatetime()
        WHERE CommentID = @CommentID AND ReporterMemberID = @MemberID;

        IF @@ROWCOUNT = 0
            INSERT INTO dsc.dsc_CommentReport (CommentID, ReporterMemberID, CommentAuthorMemberID, Reason)
            VALUES (@CommentID, @MemberID, @Author, @Reason);

        SELECT c.CommentID      AS commentId,
               c.AuthorMemberID AS authorMemberId,
               t.ReportCount    AS reportCount,
               CAST(CASE WHEN mr.ReporterMemberID IS NULL THEN 0 ELSE 1 END AS BIT) AS myReport,
               mr.Reason        AS myReason
        FROM dsc.dsc_Comment c
        CROSS APPLY (
            SELECT COUNT(*) AS ReportCount FROM dsc.dsc_CommentReport r WHERE r.CommentID = c.CommentID
        ) t
        LEFT JOIN dsc.dsc_CommentReport mr ON mr.CommentID = c.CommentID AND mr.ReporterMemberID = @MemberID
        WHERE c.CommentID = @CommentID
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;
    END
    ELSE IF @Action = 'LIST'
    BEGIN
        SELECT c.CommentID       AS commentId,
               c.ThreadID        AS threadId,
               c.AuthorMemberID  AS authorMemberId,
               c.AuthorName      AS authorName,
               c.Body            AS body,
               c.IsDeleted       AS isDeleted,
               t.ReportCount     AS reportCount,
               t.LastReportedUtc AS lastReportedUtc
        FROM dsc.dsc_Comment c
        CROSS APPLY (
            SELECT COUNT(*) AS ReportCount, MAX(r.UpdatedUtc) AS LastReportedUtc
            FROM dsc.dsc_CommentReport r WHERE r.CommentID = c.CommentID
        ) t
        WHERE c.TenantID = @TenantID AND t.ReportCount > 0
        ORDER BY t.ReportCount DESC, t.LastReportedUtc DESC
        FOR JSON PATH;
    END
    ELSE
        THROW 50099, 'DSC_ACTION_INVALID', 1;
END
GO

-------------------------------------------------------------------------------
-- dsc.dsc_MemberKarma_CRUD_JSON
-- @Action: GET  -> { "memberId": "..." }  one member's karma card
-- @Action: LIST -> (no payload) the tenant's leaderboard, best first
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dsc.dsc_MemberKarma_CRUD_JSON
    @Action  varchar(12),
    @Payload nvarchar(max) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TenantID char(32) = CONVERT(char(32), SESSION_CONTEXT(N'TenantID'));
    IF @TenantID IS NULL
        THROW 50001, 'DSC_CONTEXT_REQUIRED', 1;

    IF @Action = 'GET'
    BEGIN
        DECLARE @MemberID char(32) = JSON_VALUE(@Payload, '$.memberId');
        SELECT @MemberID                       AS memberId,
               ISNULL(k.MemberName, N'Member')  AS memberName,
               ISNULL(k.CommentCount, 0)        AS commentCount,
               ISNULL(k.LikesReceived, 0)       AS likesReceived,
               ISNULL(k.DislikesReceived, 0)    AS dislikesReceived,
               ISNULL(k.Karma, 0)               AS karma
        FROM (SELECT 1 AS x) seed
        LEFT JOIN dsc.vw_dsc_MemberKarma k ON k.TenantID = @TenantID AND k.MemberID = @MemberID
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
    END
    ELSE IF @Action = 'LIST'
    BEGIN
        SELECT MemberID AS memberId, MemberName AS memberName, CommentCount AS commentCount,
               LikesReceived AS likesReceived, DislikesReceived AS dislikesReceived, Karma AS karma
        FROM dsc.vw_dsc_MemberKarma
        WHERE TenantID = @TenantID
        ORDER BY Karma DESC, MemberName
        FOR JSON PATH;
    END
    ELSE
        THROW 50099, 'DSC_ACTION_INVALID', 1;
END
GO

-------------------------------------------------------------------------------
-- Seed data - two tenants, one thread each, char(32) IDs. Tenant A has three
-- members (Jane/Sam/Alex) so votes and karma mean something from the start.
--   Tenant A: 11111111111111111111111111111111  Thread A: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
--   Tenant B: 22222222222222222222222222222222  Thread B: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
-------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM dsc.dsc_Comment WHERE TenantID = '11111111111111111111111111111111')
BEGIN
    DECLARE @TenantA char(32) = '11111111111111111111111111111111';
    DECLARE @ThreadA char(32) = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    DECLARE @Jane char(32) = '30000000000000000000000000000001';
    DECLARE @Sam  char(32) = '30000000000000000000000000000002';
    DECLARE @Alex char(32) = '30000000000000000000000000000003';
    DECLARE @C1 char(32) = REPLACE(CONVERT(varchar(36), NEWID()), '-', '');
    DECLARE @C2 char(32) = REPLACE(CONVERT(varchar(36), NEWID()), '-', '');
    DECLARE @C3 char(32) = REPLACE(CONVERT(varchar(36), NEWID()), '-', '');

    INSERT INTO dsc.dsc_Comment (CommentID, TenantID, ThreadID, AuthorMemberID, AuthorName, Body, CreatedUtc)
    VALUES
    (@C1, @TenantA, @ThreadA, @Jane, 'Jane', 'Kicking off the thread — welcome!', DATEADD(MINUTE, -30, SYSUTCDATETIME())),
    (@C2, @TenantA, @ThreadA, @Sam,  'Sam',  'Looks good, added the API skeleton.', DATEADD(MINUTE, -20, SYSUTCDATETIME())),
    (@C3, @TenantA, @ThreadA, @Jane, 'Jane', 'DB contracts are locked, building read path next.', DATEADD(MINUTE, -10, SYSUTCDATETIME()));

    -- Sam and Alex both like Jane's opening comment.
    INSERT INTO dsc.dsc_CommentVote (CommentID, MemberID, CommentAuthorMemberID, Value)
    VALUES (@C1, @Sam, @Jane, 1), (@C1, @Alex, @Jane, 1);
    -- Alex and Jane both like Sam's comment.
    INSERT INTO dsc.dsc_CommentVote (CommentID, MemberID, CommentAuthorMemberID, Value)
    VALUES (@C2, @Alex, @Sam, 1), (@C2, @Jane, @Sam, 1);
    -- One dislike, so the counters are visibly independent of each other.
    INSERT INTO dsc.dsc_CommentVote (CommentID, MemberID, CommentAuthorMemberID, Value)
    VALUES (@C3, @Sam, @Jane, -1);
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
