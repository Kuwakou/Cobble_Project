-- 090: least-privilege login for the API. EXECUTE on dbo procedures only; every table verb is DENIED,
-- so "no direct table access from the API" is enforced by the engine, not by code review.
-- Stored procedures still work for this login through ownership chaining (proc and tables are both dbo-owned).
USE Cobble398;
GO

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'cobble_api')
    CREATE LOGIN cobble_api WITH PASSWORD = '$(ApiPassword)', CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN cobble_api WITH PASSWORD = '$(ApiPassword)';
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'cobble_api')
    CREATE USER cobble_api FOR LOGIN cobble_api;
GO
GRANT EXECUTE ON SCHEMA::dbo TO cobble_api;
DENY SELECT, INSERT, UPDATE, DELETE, ALTER, REFERENCES ON SCHEMA::dbo TO cobble_api;
GO
PRINT 'Cobble398 baseline ready';
GO
