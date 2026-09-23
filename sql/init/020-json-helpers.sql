-- 020: JSON contract helpers. Every stored procedure returns ONE row with ONE column [json]
-- shaped as either  {"ok":true,"data":<object|array|null>}  or  {"ok":false,"error":{"code":"...","message":"..."}}
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_JsonOk (@data NVARCHAR(MAX))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN N'{"ok":true,"data":' + ISNULL(@data, N'null') + N'}';
END
GO

CREATE OR ALTER FUNCTION dbo.fn_JsonError (@code NVARCHAR(40), @message NVARCHAR(400))
RETURNS NVARCHAR(MAX)
AS
BEGIN
    RETURN N'{"ok":false,"error":{"code":"' + STRING_ESCAPE(@code, 'json')
         + N'","message":"' + STRING_ESCAPE(ISNULL(@message, N''), 'json') + N'"}}';
END
GO

-- Renders one member (with its children when @IncludeChildren = 1) as a JSON object, or NULL when
-- the (TenantId, MemberId) pair does not exist. Both keys are always required: this is the tenancy fence.
CREATE OR ALTER FUNCTION dbo.tvf_MemberJson (@TenantId UNIQUEIDENTIFIER, @MemberId UNIQUEIDENTIFIER, @IncludeChildren BIT)
RETURNS TABLE
AS
RETURN
(
    SELECT
    (
        SELECT
            m.MemberId    AS [memberId],
            m.TenantId    AS [tenantId],
            m.DisplayName AS [displayName],
            m.Status      AS [status],
            m.CreatedAt   AS [createdAt],
            m.UpdatedAt   AS [updatedAt],
            JSON_QUERY(CASE WHEN @IncludeChildren = 1 THEN ISNULL((
                SELECT c.ContactId AS [contactId], c.Kind AS [kind], c.Value AS [value], c.IsPrimary AS [isPrimary], c.CreatedAt AS [createdAt]
                FROM dbo.MemberContact c
                WHERE c.TenantId = m.TenantId AND c.MemberId = m.MemberId
                ORDER BY c.IsPrimary DESC, c.CreatedAt
                FOR JSON PATH), N'[]') END) AS [contacts],
            JSON_QUERY(CASE WHEN @IncludeChildren = 1 THEN ISNULL((
                SELECT a.AddressId AS [addressId], a.Line1 AS [line1], a.Line2 AS [line2], a.City AS [city], a.State AS [state],
                       a.Postcode AS [postcode], a.Country AS [country], a.IsPrimary AS [isPrimary], a.CreatedAt AS [createdAt]
                FROM dbo.MemberAddress a
                WHERE a.TenantId = m.TenantId AND a.MemberId = m.MemberId
                ORDER BY a.IsPrimary DESC, a.CreatedAt
                FOR JSON PATH, INCLUDE_NULL_VALUES), N'[]') END) AS [addresses],
            JSON_QUERY(CASE WHEN @IncludeChildren = 1 THEN ISNULL((
                SELECT s.SkillId AS [skillId], s.Name AS [name], s.Level AS [level], s.CreatedAt AS [createdAt]
                FROM dbo.MemberSkill s
                WHERE s.TenantId = m.TenantId AND s.MemberId = m.MemberId
                ORDER BY s.Name
                FOR JSON PATH), N'[]') END) AS [skills]
        FROM dbo.Member m
        WHERE m.TenantId = @TenantId AND m.MemberId = @MemberId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS [json]
);
GO
