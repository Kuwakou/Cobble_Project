-- 120: Discussion Thread seed data for the proof of concept. Idempotent - re-running changes nothing.
--
-- TWO tenants are seeded on purpose. Tenant B exists so the negative isolation test has something
-- to NOT return: reading Tenant A's thread with Tenant B's id must come back empty / not_found.
--
-- Fixed, memorable GUIDs so anyone can paste them into Swagger or a Postman variable:
--   Tenant A            11111111-1111-1111-1111-111111111111
--   Tenant B            22222222-2222-2222-2222-222222222222
--   Thread A (the PoC)  AAAA0001-0000-0000-0000-000000000001
--   Thread B            BBBB0001-0000-0000-0000-000000000001
--   Members             00000000-0000-0000-0000-0000000000A1  Ana Nguyen  (tenant A)
--                       00000000-0000-0000-0000-0000000000B2  Ben Okafor  (tenant A)
--                       00000000-0000-0000-0000-0000000000C3  Chloe Reid  (tenant B)
USE Cobble398;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO
SET NOCOUNT ON;
GO

DECLARE @TenantA UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @TenantB UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
DECLARE @ThreadA UNIQUEIDENTIFIER = 'AAAA0001-0000-0000-0000-000000000001';
DECLARE @ThreadB UNIQUEIDENTIFIER = 'BBBB0001-0000-0000-0000-000000000001';
DECLARE @Ana     UNIQUEIDENTIFIER = '00000000-0000-0000-0000-0000000000A1';
DECLARE @Ben     UNIQUEIDENTIFIER = '00000000-0000-0000-0000-0000000000B2';
DECLARE @Chloe   UNIQUEIDENTIFIER = '00000000-0000-0000-0000-0000000000C3';
DECLARE @T0      DATETIME2(0)     = '2026-09-01T09:00:00';

MERGE dsc.Thread AS t
USING (VALUES
    (@TenantA, @ThreadA, N'Week 13 proof of concept - design questions', @T0),
    (@TenantB, @ThreadB, N'Tenant B thread (isolation control)',          @T0)
) AS s (TenantId, ThreadId, Title, CreatedAt)
   ON t.TenantId = s.TenantId AND t.ThreadId = s.ThreadId
WHEN NOT MATCHED THEN
    INSERT (TenantId, ThreadId, Title, CreatedAt)
    VALUES (s.TenantId, s.ThreadId, s.Title, s.CreatedAt);

-- Comment ids are fixed too, so the delete demo can be re-run after a rebuild.
MERGE dsc.Comment AS c
USING (VALUES
    ('C0000001-0000-0000-0000-000000000001', @TenantA, @ThreadA, @Ana,   N'Ana Nguyen',
     N'Kicking this off: are we agreed the API only ever calls stored procedures?', DATEADD(MINUTE,  0, @T0)),
    ('C0000001-0000-0000-0000-000000000002', @TenantA, @ThreadA, @Ben,   N'Ben Okafor',
     N'Yes - no SQL text in the controllers. The procedure signatures are the contract.', DATEADD(MINUTE, 12, @T0)),
    ('C0000001-0000-0000-0000-000000000003', @TenantA, @ThreadA, @Ana,   N'Ana Nguyen',
     N'And TenantId is the first parameter of every one of them, from day one.', DATEADD(MINUTE, 25, @T0)),
    ('C0000001-0000-0000-0000-000000000004', @TenantA, @ThreadA, @Ben,   N'Ben Okafor',
     N'Agreed. I will wire the UI against Swagger as soon as the seed is in.', DATEADD(MINUTE, 41, @T0)),
    ('C0000002-0000-0000-0000-000000000001', @TenantB, @ThreadB, @Chloe, N'Chloe Reid',
     N'This comment belongs to Tenant B and must never appear in a Tenant A response.', DATEADD(MINUTE,  5, @T0))
) AS s (CommentId, TenantId, ThreadId, AuthorMemberId, AuthorDisplayName, Body, CreatedAt)
   ON c.TenantId = s.TenantId AND c.CommentId = CAST(s.CommentId AS UNIQUEIDENTIFIER)
WHEN NOT MATCHED THEN
    INSERT (TenantId, CommentId, ThreadId, AuthorMemberId, AuthorDisplayName, Body, CreatedAt)
    VALUES (s.TenantId, CAST(s.CommentId AS UNIQUEIDENTIFIER), s.ThreadId, s.AuthorMemberId,
            s.AuthorDisplayName, s.Body, s.CreatedAt);
GO

DECLARE @Threads INT  = (SELECT COUNT(*) FROM dsc.Thread);
DECLARE @Comments INT = (SELECT COUNT(*) FROM dsc.Comment WHERE IsDeleted = 0);
PRINT CONCAT('dsc seed - Thread rows: ', @Threads, ' | live Comment rows: ', @Comments);
GO
