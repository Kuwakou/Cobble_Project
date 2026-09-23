-- 060: MemberSkill procedures (child of Member). Every call is scoped by (@TenantId, @MemberId).
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER FUNCTION dbo.tvf_SkillJson (@TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER, @SkillId UNIQUEIDENTIFIER)
RETURNS TABLE
AS RETURN
(
    SELECT (
        SELECT s.SkillId AS [skillId], s.MemberId AS [memberId], s.Name AS [name], s.Level AS [level], s.CreatedAt AS [createdAt]
        FROM dbo.MemberSkill s
        WHERE s.TenantId = @TenantId AND s.MemberId = @MemberId AND s.SkillId = @SkillId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS [json]
);
GO

-------------------------------------------------------------------------------
-- usp_MemberSkill_Add
-- in : { "name": "string(1..80)", "level": 1..5 }
-- out: SkillDto  |  not_found (member) | validation | conflict (duplicate name)
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberSkill_Add
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @Json     NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.Member WHERE TenantId = @TenantId AND MemberId = @MemberId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Member not found in this tenant.') AS [json]; RETURN; END

    DECLARE @Name NVARCHAR(80) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.name')));
    DECLARE @Level TINYINT = TRY_CAST(JSON_VALUE(@Json, '$.level') AS TINYINT);
    IF @Name IS NULL OR LEN(@Name) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'name is required (1-80 characters).') AS [json]; RETURN; END
    IF @Level IS NULL OR @Level NOT BETWEEN 1 AND 5
        BEGIN SELECT dbo.fn_JsonError('validation', 'level must be an integer from 1 to 5.') AS [json]; RETURN; END

    BEGIN TRY
        DECLARE @Ids TABLE (SkillId UNIQUEIDENTIFIER);
        INSERT INTO dbo.MemberSkill (TenantId, MemberId, Name, Level)
        OUTPUT inserted.SkillId INTO @Ids
        VALUES (@TenantId, @MemberId, @Name, @Level);
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;

        DECLARE @SkillId UNIQUEIDENTIFIER = (SELECT TOP 1 SkillId FROM @Ids);
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_SkillJson(@TenantId, @MemberId, @SkillId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'This member already has a skill with that name.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberSkill_Update
-- in : { "name", "level" }
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberSkill_Update
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @SkillId  UNIQUEIDENTIFIER,
    @Json     NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.MemberSkill WHERE TenantId = @TenantId AND MemberId = @MemberId AND SkillId = @SkillId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Skill not found for this member in this tenant.') AS [json]; RETURN; END

    DECLARE @Name NVARCHAR(80) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.name')));
    DECLARE @Level TINYINT = TRY_CAST(JSON_VALUE(@Json, '$.level') AS TINYINT);
    IF @Name IS NULL OR LEN(@Name) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'name is required (1-80 characters).') AS [json]; RETURN; END
    IF @Level IS NULL OR @Level NOT BETWEEN 1 AND 5
        BEGIN SELECT dbo.fn_JsonError('validation', 'level must be an integer from 1 to 5.') AS [json]; RETURN; END

    BEGIN TRY
        UPDATE dbo.MemberSkill SET Name = @Name, Level = @Level
        WHERE TenantId = @TenantId AND MemberId = @MemberId AND SkillId = @SkillId;
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_SkillJson(@TenantId, @MemberId, @SkillId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'This member already has a skill with that name.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberSkill_Remove
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberSkill_Remove
    @TenantId UNIQUEIDENTIFIER,
    @MemberId UNIQUEIDENTIFIER,
    @SkillId  UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DELETE FROM dbo.MemberSkill WHERE TenantId = @TenantId AND MemberId = @MemberId AND SkillId = @SkillId;
    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Skill not found for this member in this tenant.') AS [json];
    ELSE
    BEGIN
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        SELECT dbo.fn_JsonOk(N'{"deleted":true}') AS [json];
    END
END
GO
