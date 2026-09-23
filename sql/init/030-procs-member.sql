-- 030: Member aggregate-root procedures.
-- Contract: @TenantId is the FIRST parameter of every procedure and is always applied as a filter.
-- Input documents arrive as @Json NVARCHAR(MAX); output is the standard envelope (see 020).
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-------------------------------------------------------------------------------
-- usp_Member_Upsert: create the member on first sight (identity comes from the JWT), or update DisplayName.
-- in : { "displayName": "string(1..100)" }
-- out: MemberDto (no children)
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Member_Upsert
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @Json     NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @TenantId IS NULL OR @MemberId IS NULL
        BEGIN SELECT dbo.fn_JsonError('validation', 'tenantId and memberId are required.') AS [json]; RETURN; END
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END

    DECLARE @DisplayName NVARCHAR(100) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.displayName')));
    IF @DisplayName IS NULL OR LEN(@DisplayName) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'displayName is required (1-100 characters).') AS [json]; RETURN; END

    BEGIN TRY
        BEGIN TRAN;
        IF EXISTS (SELECT 1 FROM dbo.Member WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @TenantId AND MemberId = @MemberId)
            UPDATE dbo.Member SET DisplayName = @DisplayName, UpdatedAt = SYSUTCDATETIME()
            WHERE TenantId = @TenantId AND MemberId = @MemberId;
        ELSE
            INSERT INTO dbo.Member (TenantId, MemberId, DisplayName) VALUES (@TenantId, @MemberId, @DisplayName);
        COMMIT;

        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_MemberJson(@TenantId, @MemberId, 0);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'Duplicate value violates a uniqueness rule.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_Member_Get: the whole aggregate for one member of one tenant.
-- out: MemberDto + contacts[] + addresses[] + skills[]   |  not_found
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Member_Get
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @data NVARCHAR(MAX);
    SELECT @data = [json] FROM dbo.tvf_MemberJson(@TenantId, @MemberId, 1);
    IF @data IS NULL
        SELECT dbo.fn_JsonError('not_found', 'Member not found in this tenant.') AS [json];
    ELSE
        SELECT dbo.fn_JsonOk(@data) AS [json];
END
GO

-------------------------------------------------------------------------------
-- usp_Member_List: paged directory of a tenant (admin use).
-- in : { "page": 1, "pageSize": 20, "search": "optional substring of displayName", "status": "Active|Suspended" }
-- out: { "items": [MemberDto...], "page", "pageSize", "total" }
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Member_List
    @TenantId UNIQUEIDENTIFIER,
    @Json     NVARCHAR(MAX) = N'{}'
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL
        BEGIN SELECT dbo.fn_JsonError('validation', 'tenantId is required.') AS [json]; RETURN; END
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END

    DECLARE @Page     INT           = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.page')     AS INT), 1);
    DECLARE @PageSize INT           = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.pageSize') AS INT), 20);
    DECLARE @Search   NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@Json, '$.search'))), N'');
    DECLARE @Status   NVARCHAR(20)  = NULLIF(JSON_VALUE(@Json, '$.status'), N'');
    IF @Page < 1 SET @Page = 1;
    IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 20;

    DECLARE @Total INT = (
        SELECT COUNT(*) FROM dbo.Member m
        WHERE m.TenantId = @TenantId
          AND (@Search IS NULL OR m.DisplayName LIKE N'%' + @Search + N'%')
          AND (@Status IS NULL OR m.Status = @Status));

    DECLARE @Items NVARCHAR(MAX) = ISNULL((
        SELECT m.MemberId AS [memberId], m.TenantId AS [tenantId], m.DisplayName AS [displayName],
               m.Status AS [status], m.CreatedAt AS [createdAt], m.UpdatedAt AS [updatedAt]
        FROM dbo.Member m
        WHERE m.TenantId = @TenantId
          AND (@Search IS NULL OR m.DisplayName LIKE N'%' + @Search + N'%')
          AND (@Status IS NULL OR m.Status = @Status)
        ORDER BY m.DisplayName, m.MemberId
        OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        FOR JSON PATH), N'[]');

    SELECT dbo.fn_JsonOk((
        SELECT JSON_QUERY(@Items) AS [items], @Page AS [page], @PageSize AS [pageSize], @Total AS [total]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS [json];
END
GO

-------------------------------------------------------------------------------
-- usp_Member_SetStatus
-- in : { "status": "Active" | "Suspended" }
-- out: MemberDto  |  not_found | validation
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Member_SetStatus
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @Json     NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @Status NVARCHAR(20) = JSON_VALUE(@Json, '$.status');
    IF @Status IS NULL OR @Status NOT IN (N'Active', N'Suspended')
        BEGIN SELECT dbo.fn_JsonError('validation', 'status must be Active or Suspended.') AS [json]; RETURN; END

    UPDATE dbo.Member SET Status = @Status, UpdatedAt = SYSUTCDATETIME()
    WHERE TenantId = @TenantId AND MemberId = @MemberId;

    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Member not found in this tenant.') AS [json];
    ELSE
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_MemberJson(@TenantId, @MemberId, 0);
END
GO

-------------------------------------------------------------------------------
-- usp_Member_Delete: removes the member and (by cascade) its whole profile.
-- out: { "deleted": true }  |  not_found
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Member_Delete
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DELETE FROM dbo.Member WHERE TenantId = @TenantId AND MemberId = @MemberId;
    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Member not found in this tenant.') AS [json];
    ELSE
        SELECT dbo.fn_JsonOk(N'{"deleted":true}') AS [json];
END
GO
