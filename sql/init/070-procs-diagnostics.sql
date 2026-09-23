-- 070: diagnostics + Week 0 scaffold procedures (kept for the environment smoke test and the UI demo).
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

-- usp_Ping: what the /api/ping endpoint and the health page show. No tenant data, no secrets.
CREATE OR ALTER PROCEDURE dbo.usp_Ping
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DB_NAME()          AS [database],
           @@SERVERNAME       AS [server],
           SYSUTCDATETIME()   AS [utcNow],
           (SELECT COUNT(*) FROM dbo.TenantTest) AS [totalRows],
           (SELECT COUNT(*) FROM dbo.Member)     AS [members],
           (SELECT COUNT(DISTINCT TenantId) FROM dbo.Member) AS [tenants]
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_TenantTest_List
    @TenantId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT dbo.fn_JsonOk(ISNULL((
        SELECT Id AS [id], TenantId AS [tenantId], Name AS [name], CreatedAt AS [createdAt]
        FROM dbo.TenantTest
        WHERE TenantId = @TenantId
        ORDER BY Id
        FOR JSON PATH), N'[]')) AS [json];
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_TenantTest_Insert
    @TenantId UNIQUEIDENTIFIER,
    @Name     NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    IF @TenantId IS NULL OR @Name IS NULL OR LEN(LTRIM(RTRIM(@Name))) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'name is required.') AS [json]; RETURN; END
    INSERT INTO dbo.TenantTest (TenantId, Name) VALUES (@TenantId, LTRIM(RTRIM(@Name)));
    DECLARE @Id INT = SCOPE_IDENTITY();
    SELECT dbo.fn_JsonOk((
        SELECT Id AS [id], TenantId AS [tenantId], Name AS [name], CreatedAt AS [createdAt]
        FROM dbo.TenantTest WHERE Id = @Id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS [json];
END
GO
