-- Negative tenant-isolation test (Week 2). Run as sa:
--   sqlcmd -S localhost -U sa -P ... -C -b -d Cobble398 -i /usr/src/app/tests/tenant-isolation.sql
-- Every case tries to reach Tenant A's data while claiming to be Tenant B, through every path an attacker
-- (or a buggy API) could take. Expected result for each: NOT_FOUND / error, and Tenant A's data untouched.
-- Exit code is non-zero if any case fails (THROW at the end + sqlcmd -b).
USE Cobble398;
SET NOCOUNT ON;

DECLARE @A  UNIQUEIDENTIFIER = 'AAAAAAAA-0000-4000-8000-0000000000AA';  -- victim tenant
DECLARE @B  UNIQUEIDENTIFIER = 'BBBBBBBB-0000-4000-8000-0000000000BB';  -- attacking tenant
DECLARE @MA UNIQUEIDENTIFIER = 'AAAAAAAA-1111-4000-8000-00000000000A';  -- member of A
DECLARE @MB UNIQUEIDENTIFIER = 'BBBBBBBB-1111-4000-8000-00000000000B';  -- member of B

DECLARE @r TABLE ([json] NVARCHAR(MAX));
DECLARE @j NVARCHAR(MAX), @fail INT = 0, @pass INT = 0, @n INT;
DECLARE @ContactId UNIQUEIDENTIFIER, @AddressId UNIQUEIDENTIFIER, @SkillId UNIQUEIDENTIFIER;

-- clean slate
DELETE FROM dbo.Member WHERE TenantId IN (@A, @B);

PRINT '=== Negative tenant isolation test ===';

-------------------------------------------------------------------------------
-- T01 setup: a member in each tenant, and a full profile for the victim
-------------------------------------------------------------------------------
INSERT @r EXEC dbo.usp_Member_Upsert @A, @MA, N'{"displayName":"Alice (tenant A)"}';
INSERT @r EXEC dbo.usp_Member_Upsert @B, @MB, N'{"displayName":"Bob (tenant B)"}';
DELETE @r; INSERT @r EXEC dbo.usp_MemberContact_Add @A, @MA, N'{"kind":"Email","value":"alice@a.example","isPrimary":true}';
SELECT @ContactId = JSON_VALUE([json], '$.data.contactId') FROM @r;
DELETE @r; INSERT @r EXEC dbo.usp_MemberAddress_Add @A, @MA, N'{"line1":"1 A St","city":"Brisbane","postcode":"4000","country":"au","isPrimary":true}';
SELECT @AddressId = JSON_VALUE([json], '$.data.addressId') FROM @r;
DELETE @r; INSERT @r EXEC dbo.usp_MemberSkill_Add @A, @MA, N'{"name":"SQL","level":4}';
SELECT @SkillId = JSON_VALUE([json], '$.data.skillId') FROM @r;
IF @ContactId IS NOT NULL AND @AddressId IS NOT NULL AND @SkillId IS NOT NULL
    BEGIN SET @pass += 1; PRINT 'PASS T01 setup: member A has contact, address, skill'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T01 setup'; END

-------------------------------------------------------------------------------
-- T02 cross-tenant read of the aggregate
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_Member_Get @B, @MA;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.ok') = 'false' AND JSON_VALUE(@j, '$.error.code') = 'not_found'
    BEGIN SET @pass += 1; PRINT 'PASS T02 usp_Member_Get(B, memberOfA) -> not_found'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T02 usp_Member_Get(B, memberOfA) returned: ' + @j; END

-------------------------------------------------------------------------------
-- T03 cross-tenant directory listing must not leak A's member
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_Member_List @B, N'{"pageSize":200}';
SELECT @j = [json] FROM @r;
IF @j NOT LIKE '%' + CAST(@MA AS NVARCHAR(36)) + '%' AND @j LIKE '%' + CAST(@MB AS NVARCHAR(36)) + '%'
    BEGIN SET @pass += 1; PRINT 'PASS T03 usp_Member_List(B) shows B only'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T03 usp_Member_List(B) leaked: ' + @j; END

-------------------------------------------------------------------------------
-- T04 cross-tenant child ADD (B tries to attach a contact to A's member)
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_MemberContact_Add @B, @MA, N'{"kind":"Phone","value":"+61 400 000 000"}';
SELECT @j = [json] FROM @r;
SELECT @n = COUNT(*) FROM dbo.MemberContact WHERE MemberId = @MA;
IF JSON_VALUE(@j, '$.error.code') = 'not_found' AND @n = 1
    BEGIN SET @pass += 1; PRINT 'PASS T04 usp_MemberContact_Add(B, memberOfA) -> not_found, no row added'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T04 ' + @j; END

-------------------------------------------------------------------------------
-- T05 cross-tenant child UPDATE using A's real ContactId (IDOR attempt)
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_MemberContact_Update @B, @MA, @ContactId, N'{"kind":"Email","value":"hacked@b.example","isPrimary":true}';
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'not_found'
   AND EXISTS (SELECT 1 FROM dbo.MemberContact WHERE ContactId = @ContactId AND Value = N'alice@a.example')
    BEGIN SET @pass += 1; PRINT 'PASS T05 usp_MemberContact_Update(B, memberOfA, realContactId) -> not_found, value unchanged'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T05 ' + @j; END

-------------------------------------------------------------------------------
-- T06 cross-tenant child REMOVE using real ids (contact, address, skill)
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_MemberContact_Remove @B, @MA, @ContactId;
INSERT @r EXEC dbo.usp_MemberAddress_Remove @B, @MA, @AddressId;
INSERT @r EXEC dbo.usp_MemberSkill_Remove  @B, @MA, @SkillId;
SELECT @n = COUNT(*) FROM @r WHERE JSON_VALUE([json], '$.error.code') = 'not_found';
IF @n = 3
   AND EXISTS (SELECT 1 FROM dbo.MemberContact WHERE ContactId = @ContactId)
   AND EXISTS (SELECT 1 FROM dbo.MemberAddress WHERE AddressId = @AddressId)
   AND EXISTS (SELECT 1 FROM dbo.MemberSkill   WHERE SkillId   = @SkillId)
    BEGIN SET @pass += 1; PRINT 'PASS T06 *_Remove(B, memberOfA, realId) x3 -> not_found, rows intact'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T06 cross-tenant remove'; END

-------------------------------------------------------------------------------
-- T07 cross-tenant status change and T08 cross-tenant delete of the root
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_Member_SetStatus @B, @MA, N'{"status":"Suspended"}';
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'not_found' AND EXISTS (SELECT 1 FROM dbo.Member WHERE MemberId = @MA AND Status = N'Active')
    BEGIN SET @pass += 1; PRINT 'PASS T07 usp_Member_SetStatus(B, memberOfA) -> not_found, still Active'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T07 ' + @j; END

DELETE @r; INSERT @r EXEC dbo.usp_Member_Delete @B, @MA;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.error.code') = 'not_found' AND EXISTS (SELECT 1 FROM dbo.Member WHERE MemberId = @MA)
    BEGIN SET @pass += 1; PRINT 'PASS T08 usp_Member_Delete(B, memberOfA) -> not_found, member intact'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T08 ' + @j; END

-------------------------------------------------------------------------------
-- T09 engine-level fence: even bypassing the procedures, a child row cannot point across tenants
-------------------------------------------------------------------------------
BEGIN TRY
    INSERT INTO dbo.MemberContact (TenantId, MemberId, Kind, Value) VALUES (@B, @MA, N'Other', N'cross-tenant row');
    SET @fail += 1; PRINT 'FAIL T09 direct INSERT with mismatched TenantId was accepted';
    DELETE FROM dbo.MemberContact WHERE TenantId = @B AND MemberId = @MA;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 547
        BEGIN SET @pass += 1; PRINT 'PASS T09 direct INSERT (TenantId=B, MemberId=A) rejected by FK_MemberContact_Member (error 547)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T09 unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE(); END
END CATCH

-------------------------------------------------------------------------------
-- T10 NULL tenant is impossible on every table
-------------------------------------------------------------------------------
BEGIN TRY
    INSERT INTO dbo.Member (TenantId, MemberId, DisplayName) VALUES (NULL, NEWID(), N'no tenant');
    SET @fail += 1; PRINT 'FAIL T10 NULL TenantId accepted';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 515
        BEGIN SET @pass += 1; PRINT 'PASS T10 INSERT with NULL TenantId rejected (error 515)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T10 unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)); END
END CATCH

-------------------------------------------------------------------------------
-- T11 permission fence: the API login cannot read tables, but can execute procedures
-------------------------------------------------------------------------------
EXECUTE AS USER = 'cobble_api';
BEGIN TRY
    SELECT @n = COUNT(*) FROM dbo.Member;
    SET @fail += 1; PRINT 'FAIL T11a cobble_api could SELECT from dbo.Member';
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 229
        BEGIN SET @pass += 1; PRINT 'PASS T11a cobble_api SELECT on dbo.Member denied (error 229)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T11a unexpected error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)); END
END CATCH
BEGIN TRY
    DELETE @r; INSERT @r EXEC dbo.usp_Member_Get @A, @MA;
    SELECT @j = [json] FROM @r;
    IF JSON_VALUE(@j, '$.ok') = 'true' AND JSON_VALUE(@j, '$.data.displayName') = N'Alice (tenant A)'
        BEGIN SET @pass += 1; PRINT 'PASS T11b cobble_api EXEC usp_Member_Get(A, memberOfA) -> ok (ownership chaining)'; END
    ELSE
        BEGIN SET @fail += 1; PRINT 'FAIL T11b ' + ISNULL(@j, 'null'); END
END TRY
BEGIN CATCH
    SET @fail += 1; PRINT 'FAIL T11b error ' + ERROR_MESSAGE();
END CATCH
REVERT;

-------------------------------------------------------------------------------
-- T12 positive control: the owning tenant CAN see and change its own data, and delete cascades
-------------------------------------------------------------------------------
DELETE @r; INSERT @r EXEC dbo.usp_Member_Get @A, @MA;
SELECT @j = [json] FROM @r;
IF JSON_VALUE(@j, '$.ok') = 'true'
   AND JSON_VALUE(@j, '$.data.contacts[0].value') = N'alice@a.example'
   AND JSON_VALUE(@j, '$.data.addresses[0].country') = N'AU'
   AND JSON_VALUE(@j, '$.data.skills[0].name') = N'SQL'
    BEGIN SET @pass += 1; PRINT 'PASS T12a usp_Member_Get(A, memberOfA) -> full aggregate'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T12a ' + @j; END

DELETE @r; INSERT @r EXEC dbo.usp_Member_Delete @A, @MA;
SELECT @n = (SELECT COUNT(*) FROM dbo.MemberContact WHERE MemberId = @MA)
          + (SELECT COUNT(*) FROM dbo.MemberAddress WHERE MemberId = @MA)
          + (SELECT COUNT(*) FROM dbo.MemberSkill   WHERE MemberId = @MA);
IF @n = 0 AND NOT EXISTS (SELECT 1 FROM dbo.Member WHERE MemberId = @MA)
    BEGIN SET @pass += 1; PRINT 'PASS T12b usp_Member_Delete(A, memberOfA) cascaded to all children'; END
ELSE
    BEGIN SET @fail += 1; PRINT 'FAIL T12b cascade left ' + CAST(@n AS NVARCHAR(10)) + ' child rows'; END

-- cleanup
DELETE FROM dbo.Member WHERE TenantId IN (@A, @B);

PRINT '=== Result: ' + CAST(@pass AS NVARCHAR(10)) + ' passed, ' + CAST(@fail AS NVARCHAR(10)) + ' failed ===';
IF @fail > 0 THROW 50001, 'Tenant isolation test FAILED', 1;
