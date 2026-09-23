-- 190: least-privilege grants for the discussion schema. Runs after 090-security.sql, which
-- creates the cobble_api login and does the same for dbo.
--
-- The API may EXECUTE dsc procedures and nothing else. Every table verb is DENIED, so
-- "no direct table access from the API" is enforced by the engine, not by code review.
-- The procedures still reach dsc.Comment / dsc.Thread through ownership chaining, because
-- schema dsc was created AUTHORIZATION dbo (see 100-discussion-tables.sql).
USE Cobble398;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'cobble_api')
    THROW 50000, 'cobble_api user is missing - 090-security.sql must run before 190.', 1;
GO

GRANT EXECUTE ON SCHEMA::dsc TO cobble_api;
DENY SELECT, INSERT, UPDATE, DELETE, ALTER, REFERENCES ON SCHEMA::dsc TO cobble_api;
GO

DECLARE @Tables INT = (SELECT COUNT(*) FROM sys.tables     WHERE schema_id = SCHEMA_ID('dsc'));
DECLARE @Procs  INT = (SELECT COUNT(*) FROM sys.procedures WHERE schema_id = SCHEMA_ID('dsc'));
PRINT CONCAT('dsc ready - tables: ', @Tables, ' | procedures: ', @Procs);
GO
