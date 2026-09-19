IF DB_ID('CobbleDb') IS NULL
    CREATE DATABASE CobbleDb;
GO

USE CobbleDb;
GO

IF OBJECT_ID('dbo.HealthProbe', 'U') IS NULL
    CREATE TABLE dbo.HealthProbe (
        Id        INT IDENTITY(1,1) PRIMARY KEY,
        TenantId  UNIQUEIDENTIFIER NOT NULL,
        Note      NVARCHAR(200)    NOT NULL,
        CreatedAt DATETIME2        NOT NULL DEFAULT SYSUTCDATETIME()
    );
GO
