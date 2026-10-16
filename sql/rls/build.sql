/* Discussion Thread module - RLS install. Target: a database used for
   integration/tenancy testing (point SQL_DATABASE at one if you use this
   path instead of ../no-rls/build.sql).

   This proves what no-rls can't: that a query which forgets
   "WHERE TenantID = ..." still cannot read another tenant's rows, because
   SQL Server's own Row-Level Security enforces it from SESSION_CONTEXT,
   independent of application code.

   Order matters: first build the table/proc/seed (same script as no-rls),
   THEN add the security policy - the policy's predicate function has to
   reference a table that already exists. */

:r /init/no-rls/build.sql
GO

-------------------------------------------------------------------------------
-- Tenant filter predicate. Runs for every statement against dsc.dsc_Comment,
-- for every login - including sa/dbo, there's no built-in sysadmin bypass.
-- That's fine here because the API always calls sp_set_session_context
-- with the caller's validated TenantID before it queries, so the predicate
-- always has a real value to check against.
-------------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dsc.fn_Comment_TenantPredicate(@TenantID char(32))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS fn_securitypredicate_result
WHERE @TenantID = CONVERT(char(32), SESSION_CONTEXT(N'TenantID'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.security_policies WHERE name = 'dsc_Comment_TenantPolicy')
BEGIN
    CREATE SECURITY POLICY dsc.dsc_Comment_TenantPolicy
        ADD FILTER PREDICATE dsc.fn_Comment_TenantPredicate(TenantID) ON dsc.dsc_Comment,
        ADD BLOCK PREDICATE dsc.fn_Comment_TenantPredicate(TenantID) ON dsc.dsc_Comment AFTER INSERT
        WITH (STATE = ON);
END
GO

PRINT 'dsc RLS policy active on dsc.dsc_Comment.';
GO
