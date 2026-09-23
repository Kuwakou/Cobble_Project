-- 040: MemberContact procedures (child of Member). Every call is scoped by (@TenantId, @MemberId).
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER FUNCTION dbo.tvf_ContactJson (@TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER, @ContactId UNIQUEIDENTIFIER)
RETURNS TABLE
AS RETURN
(
    SELECT (
        SELECT c.ContactId AS [contactId], c.MemberId AS [memberId], c.Kind AS [kind], c.Value AS [value],
               c.IsPrimary AS [isPrimary], c.CreatedAt AS [createdAt]
        FROM dbo.MemberContact c
        WHERE c.TenantId = @TenantId AND c.MemberId = @MemberId AND c.ContactId = @ContactId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS [json]
);
GO

-------------------------------------------------------------------------------
-- usp_MemberContact_Add
-- in : { "kind": "Email|Phone|Other", "value": "string(1..200)", "isPrimary": bool }
-- out: ContactDto  |  not_found (member) | validation
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberContact_Add
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

    DECLARE @Kind NVARCHAR(10) = JSON_VALUE(@Json, '$.kind');
    DECLARE @Value NVARCHAR(200) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.value')));
    DECLARE @IsPrimary BIT = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.isPrimary') AS BIT), 0);
    IF @Kind NOT IN (N'Email', N'Phone', N'Other') OR @Kind IS NULL
        BEGIN SELECT dbo.fn_JsonError('validation', 'kind must be Email, Phone or Other.') AS [json]; RETURN; END
    IF @Value IS NULL OR LEN(@Value) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'value is required (1-200 characters).') AS [json]; RETURN; END

    BEGIN TRY
        DECLARE @Ids TABLE (ContactId UNIQUEIDENTIFIER);
        BEGIN TRAN;
        IF @IsPrimary = 1
            UPDATE dbo.MemberContact SET IsPrimary = 0 WHERE TenantId = @TenantId AND MemberId = @MemberId AND IsPrimary = 1;
        INSERT INTO dbo.MemberContact (TenantId, MemberId, Kind, Value, IsPrimary)
        OUTPUT inserted.ContactId INTO @Ids
        VALUES (@TenantId, @MemberId, @Kind, @Value, @IsPrimary);
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        COMMIT;

        DECLARE @ContactId UNIQUEIDENTIFIER = (SELECT TOP 1 ContactId FROM @Ids);
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_ContactJson(@TenantId, @MemberId, @ContactId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'Only one primary contact is allowed.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberContact_Update (full replace of the editable fields)
-- in : { "kind", "value", "isPrimary" }
-- out: ContactDto  |  not_found | validation
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberContact_Update
    @TenantId  UNIQUEIDENTIFIER,
    @MemberId  UNIQUEIDENTIFIER,
    @ContactId UNIQUEIDENTIFIER,
    @Json      NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.MemberContact WHERE TenantId = @TenantId AND MemberId = @MemberId AND ContactId = @ContactId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Contact not found for this member in this tenant.') AS [json]; RETURN; END

    DECLARE @Kind NVARCHAR(10) = JSON_VALUE(@Json, '$.kind');
    DECLARE @Value NVARCHAR(200) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.value')));
    DECLARE @IsPrimary BIT = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.isPrimary') AS BIT), 0);
    IF @Kind NOT IN (N'Email', N'Phone', N'Other') OR @Kind IS NULL
        BEGIN SELECT dbo.fn_JsonError('validation', 'kind must be Email, Phone or Other.') AS [json]; RETURN; END
    IF @Value IS NULL OR LEN(@Value) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'value is required (1-200 characters).') AS [json]; RETURN; END

    BEGIN TRY
        BEGIN TRAN;
        IF @IsPrimary = 1
            UPDATE dbo.MemberContact SET IsPrimary = 0
            WHERE TenantId = @TenantId AND MemberId = @MemberId AND IsPrimary = 1 AND ContactId <> @ContactId;
        UPDATE dbo.MemberContact SET Kind = @Kind, Value = @Value, IsPrimary = @IsPrimary
        WHERE TenantId = @TenantId AND MemberId = @MemberId AND ContactId = @ContactId;
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        COMMIT;
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_ContactJson(@TenantId, @MemberId, @ContactId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'Only one primary contact is allowed.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberContact_Remove
-- out: { "deleted": true }  |  not_found
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberContact_Remove
    @TenantId  UNIQUEIDENTIFIER,
    @MemberId  UNIQUEIDENTIFIER,
    @ContactId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DELETE FROM dbo.MemberContact WHERE TenantId = @TenantId AND MemberId = @MemberId AND ContactId = @ContactId;
    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Contact not found for this member in this tenant.') AS [json];
    ELSE
    BEGIN
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        SELECT dbo.fn_JsonOk(N'{"deleted":true}') AS [json];
    END
END
GO
