-- 010: Membership aggregate schema (Week 2).
-- Tenancy rule: EVERY table carries TenantId UNIQUEIDENTIFIER NOT NULL as the leading key column,
-- and every child row references its parent by the composite (TenantId, MemberId) so a child can
-- never point at a member in a different tenant - the engine enforces it, not just the procedures.
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
SET NOCOUNT ON;
GO

-------------------------------------------------------------------------------
-- Member (aggregate root). MemberId is the identity from the JWT, never generated here.
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.Member', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Member
    (
        TenantId    UNIQUEIDENTIFIER NOT NULL,
        MemberId    UNIQUEIDENTIFIER NOT NULL,
        DisplayName NVARCHAR(100)    NOT NULL,
        Status      NVARCHAR(20)     NOT NULL CONSTRAINT DF_Member_Status DEFAULT N'Active',
        CreatedAt   DATETIME2(0)     NOT NULL CONSTRAINT DF_Member_CreatedAt DEFAULT SYSUTCDATETIME(),
        UpdatedAt   DATETIME2(0)     NOT NULL CONSTRAINT DF_Member_UpdatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_Member        PRIMARY KEY CLUSTERED (TenantId, MemberId),
        CONSTRAINT CK_Member_Status CHECK (Status IN (N'Active', N'Suspended'))
    );
    CREATE INDEX IX_Member_Tenant_DisplayName ON dbo.Member (TenantId, DisplayName);
END
GO

-------------------------------------------------------------------------------
-- MemberContact (child)
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.MemberContact', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MemberContact
    (
        TenantId   UNIQUEIDENTIFIER NOT NULL,
        MemberId   UNIQUEIDENTIFIER NOT NULL,
        ContactId  UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_MemberContact_Id DEFAULT NEWSEQUENTIALID(),
        Kind       NVARCHAR(10)     NOT NULL,
        Value      NVARCHAR(200)    NOT NULL,
        IsPrimary  BIT              NOT NULL CONSTRAINT DF_MemberContact_IsPrimary DEFAULT 0,
        CreatedAt  DATETIME2(0)     NOT NULL CONSTRAINT DF_MemberContact_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MemberContact PRIMARY KEY CLUSTERED (TenantId, MemberId, ContactId),
        CONSTRAINT FK_MemberContact_Member FOREIGN KEY (TenantId, MemberId)
            REFERENCES dbo.Member (TenantId, MemberId) ON DELETE CASCADE,
        CONSTRAINT CK_MemberContact_Kind CHECK (Kind IN (N'Email', N'Phone', N'Other'))
    );
    -- at most one primary contact per member
    CREATE UNIQUE INDEX UX_MemberContact_Primary ON dbo.MemberContact (TenantId, MemberId) WHERE IsPrimary = 1;
END
GO

-------------------------------------------------------------------------------
-- MemberAddress (child)
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.MemberAddress', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MemberAddress
    (
        TenantId   UNIQUEIDENTIFIER NOT NULL,
        MemberId   UNIQUEIDENTIFIER NOT NULL,
        AddressId  UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_MemberAddress_Id DEFAULT NEWSEQUENTIALID(),
        Line1      NVARCHAR(120)    NOT NULL,
        Line2      NVARCHAR(120)    NULL,
        City       NVARCHAR(80)     NOT NULL,
        State      NVARCHAR(80)     NULL,
        Postcode   NVARCHAR(20)     NOT NULL,
        Country    CHAR(2)          NOT NULL,           -- ISO 3166-1 alpha-2
        IsPrimary  BIT              NOT NULL CONSTRAINT DF_MemberAddress_IsPrimary DEFAULT 0,
        CreatedAt  DATETIME2(0)     NOT NULL CONSTRAINT DF_MemberAddress_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MemberAddress PRIMARY KEY CLUSTERED (TenantId, MemberId, AddressId),
        CONSTRAINT FK_MemberAddress_Member FOREIGN KEY (TenantId, MemberId)
            REFERENCES dbo.Member (TenantId, MemberId) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX UX_MemberAddress_Primary ON dbo.MemberAddress (TenantId, MemberId) WHERE IsPrimary = 1;
END
GO

-------------------------------------------------------------------------------
-- MemberSkill (child)
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.MemberSkill', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MemberSkill
    (
        TenantId   UNIQUEIDENTIFIER NOT NULL,
        MemberId   UNIQUEIDENTIFIER NOT NULL,
        SkillId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_MemberSkill_Id DEFAULT NEWSEQUENTIALID(),
        Name       NVARCHAR(80)     NOT NULL,
        Level      TINYINT          NOT NULL,
        CreatedAt  DATETIME2(0)     NOT NULL CONSTRAINT DF_MemberSkill_CreatedAt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_MemberSkill PRIMARY KEY CLUSTERED (TenantId, MemberId, SkillId),
        CONSTRAINT FK_MemberSkill_Member FOREIGN KEY (TenantId, MemberId)
            REFERENCES dbo.Member (TenantId, MemberId) ON DELETE CASCADE,
        CONSTRAINT CK_MemberSkill_Level CHECK (Level BETWEEN 1 AND 5),
        CONSTRAINT UQ_MemberSkill_Name UNIQUE (TenantId, MemberId, Name)
    );
END
GO

-------------------------------------------------------------------------------
-- Week 0 scaffold table, kept for the environment smoke test (usp_Ping / usp_TenantTest_*).
-------------------------------------------------------------------------------
IF OBJECT_ID('dbo.TenantTest', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.TenantTest
    (
        Id        INT IDENTITY(1,1)  NOT NULL CONSTRAINT PK_TenantTest PRIMARY KEY,
        TenantId  UNIQUEIDENTIFIER   NOT NULL,
        Name      NVARCHAR(100)      NOT NULL,
        CreatedAt DATETIME2(0)       NOT NULL CONSTRAINT DF_TenantTest_CreatedAt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_TenantTest_TenantId ON dbo.TenantTest (TenantId);
END
GO

-------------------------------------------------------------------------------
-- Guard: every user table in this schema MUST have TenantId UNIQUEIDENTIFIER NOT NULL.
-- Fails the deployment if someone adds a table without it.
-------------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.tables t
    WHERE t.schema_id = SCHEMA_ID('dbo')
      AND NOT EXISTS (
          SELECT 1 FROM sys.columns c
          JOIN sys.types ty ON ty.user_type_id = c.user_type_id
          WHERE c.object_id = t.object_id AND c.name = 'TenantId'
            AND ty.name = 'uniqueidentifier' AND c.is_nullable = 0))
BEGIN
    THROW 50000, 'Tenancy guard: a dbo table is missing TenantId UNIQUEIDENTIFIER NOT NULL.', 1;
END
GO
