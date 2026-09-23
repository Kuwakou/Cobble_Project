-- 050: MemberAddress procedures (child of Member). Every call is scoped by (@TenantId, @MemberId).
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER FUNCTION dbo.tvf_AddressJson (@TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER, @AddressId UNIQUEIDENTIFIER)
RETURNS TABLE
AS RETURN
(
    SELECT (
        SELECT a.AddressId AS [addressId], a.MemberId AS [memberId], a.Line1 AS [line1], a.Line2 AS [line2], a.City AS [city],
               a.State AS [state], a.Postcode AS [postcode], a.Country AS [country], a.IsPrimary AS [isPrimary], a.CreatedAt AS [createdAt]
        FROM dbo.MemberAddress a
        WHERE a.TenantId = @TenantId AND a.MemberId = @MemberId AND a.AddressId = @AddressId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES) AS [json]
);
GO

-------------------------------------------------------------------------------
-- usp_MemberAddress_Add
-- in : { "line1": "string(1..120)", "line2": "string?", "city": "string(1..80)", "state": "string?",
--        "postcode": "string(1..20)", "country": "ISO-3166 alpha-2", "isPrimary": bool }
-- out: AddressDto  |  not_found (member) | validation
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberAddress_Add
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

    DECLARE @Line1 NVARCHAR(120) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.line1')));
    DECLARE @Line2 NVARCHAR(120) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@Json, '$.line2'))), N'');
    DECLARE @City NVARCHAR(80) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.city')));
    DECLARE @State NVARCHAR(80) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@Json, '$.state'))), N'');
    DECLARE @Postcode NVARCHAR(20) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.postcode')));
    DECLARE @Country CHAR(2) = UPPER(JSON_VALUE(@Json, '$.country'));
    DECLARE @IsPrimary BIT = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.isPrimary') AS BIT), 0);
    IF @Line1 IS NULL OR LEN(@Line1) = 0 OR @City IS NULL OR LEN(@City) = 0 OR @Postcode IS NULL OR LEN(@Postcode) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'line1, city and postcode are required.') AS [json]; RETURN; END
    IF @Country IS NULL OR LEN(@Country) <> 2 OR @Country LIKE '%[^A-Z]%'
        BEGIN SELECT dbo.fn_JsonError('validation', 'country must be a 2-letter ISO code.') AS [json]; RETURN; END

    BEGIN TRY
        DECLARE @Ids TABLE (AddressId UNIQUEIDENTIFIER);
        BEGIN TRAN;
        IF @IsPrimary = 1
            UPDATE dbo.MemberAddress SET IsPrimary = 0 WHERE TenantId = @TenantId AND MemberId = @MemberId AND IsPrimary = 1;
        INSERT INTO dbo.MemberAddress (TenantId, MemberId, Line1, Line2, City, State, Postcode, Country, IsPrimary)
        OUTPUT inserted.AddressId INTO @Ids
        VALUES (@TenantId, @MemberId, @Line1, @Line2, @City, @State, @Postcode, @Country, @IsPrimary);
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        COMMIT;

        DECLARE @AddressId UNIQUEIDENTIFIER = (SELECT TOP 1 AddressId FROM @Ids);
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_AddressJson(@TenantId, @MemberId, @AddressId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'Only one primary address is allowed.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberAddress_Update (full replace)
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberAddress_Update
    @TenantId  UNIQUEIDENTIFIER,
    @MemberId  UNIQUEIDENTIFIER,
    @AddressId UNIQUEIDENTIFIER,
    @Json      NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    IF ISJSON(@Json) <> 1
        BEGIN SELECT dbo.fn_JsonError('validation', 'Body must be a JSON object.') AS [json]; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM dbo.MemberAddress WHERE TenantId = @TenantId AND MemberId = @MemberId AND AddressId = @AddressId)
        BEGIN SELECT dbo.fn_JsonError('not_found', 'Address not found for this member in this tenant.') AS [json]; RETURN; END

    DECLARE @Line1 NVARCHAR(120) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.line1')));
    DECLARE @Line2 NVARCHAR(120) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@Json, '$.line2'))), N'');
    DECLARE @City NVARCHAR(80) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.city')));
    DECLARE @State NVARCHAR(80) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@Json, '$.state'))), N'');
    DECLARE @Postcode NVARCHAR(20) = LTRIM(RTRIM(JSON_VALUE(@Json, '$.postcode')));
    DECLARE @Country CHAR(2) = UPPER(JSON_VALUE(@Json, '$.country'));
    DECLARE @IsPrimary BIT = ISNULL(TRY_CAST(JSON_VALUE(@Json, '$.isPrimary') AS BIT), 0);
    IF @Line1 IS NULL OR LEN(@Line1) = 0 OR @City IS NULL OR LEN(@City) = 0 OR @Postcode IS NULL OR LEN(@Postcode) = 0
        BEGIN SELECT dbo.fn_JsonError('validation', 'line1, city and postcode are required.') AS [json]; RETURN; END
    IF @Country IS NULL OR LEN(@Country) <> 2 OR @Country LIKE '%[^A-Z]%'
        BEGIN SELECT dbo.fn_JsonError('validation', 'country must be a 2-letter ISO code.') AS [json]; RETURN; END

    BEGIN TRY
        BEGIN TRAN;
        IF @IsPrimary = 1
            UPDATE dbo.MemberAddress SET IsPrimary = 0
            WHERE TenantId = @TenantId AND MemberId = @MemberId AND IsPrimary = 1 AND AddressId <> @AddressId;
        UPDATE dbo.MemberAddress
           SET Line1 = @Line1, Line2 = @Line2, City = @City, State = @State, Postcode = @Postcode, Country = @Country, IsPrimary = @IsPrimary
        WHERE TenantId = @TenantId AND MemberId = @MemberId AND AddressId = @AddressId;
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        COMMIT;
        SELECT dbo.fn_JsonOk([json]) AS [json] FROM dbo.tvf_AddressJson(@TenantId, @MemberId, @AddressId);
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        IF ERROR_NUMBER() IN (2627, 2601) SELECT dbo.fn_JsonError('conflict', 'Only one primary address is allowed.') AS [json];
        ELSE IF ERROR_NUMBER() = 547     SELECT dbo.fn_JsonError('validation', ERROR_MESSAGE()) AS [json];
        ELSE THROW;
    END CATCH
END
GO

-------------------------------------------------------------------------------
-- usp_MemberAddress_Remove
-------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_MemberAddress_Remove
    @TenantId  UNIQUEIDENTIFIER,
    @MemberId  UNIQUEIDENTIFIER,
    @AddressId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DELETE FROM dbo.MemberAddress WHERE TenantId = @TenantId AND MemberId = @MemberId AND AddressId = @AddressId;
    IF @@ROWCOUNT = 0
        SELECT dbo.fn_JsonError('not_found', 'Address not found for this member in this tenant.') AS [json];
    ELSE
    BEGIN
        UPDATE dbo.Member SET UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @TenantId AND MemberId = @MemberId;
        SELECT dbo.fn_JsonOk(N'{"deleted":true}') AS [json];
    END
END
GO
