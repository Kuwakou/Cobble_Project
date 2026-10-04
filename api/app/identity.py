"""
Identity for this API, mirroring the Cobbled EDP reference module's pattern
(see api/Program.cs's ReadScopeAsync / the /standalone/context harness in
Cobbled-EDP-3.0.0): the API never trusts tenantId/memberId from the request
body or from hard-coded constants. It reads them from a signed token.

Production shape (not fully real here - see below):
  1. A host shell delivers a signed token to the UI.
  2. The UI sends it as `Authorization: Bearer <token>`.
  3. This module validates the signature/issuer/audience/expiry and returns
     a Scope (tenantId, memberId, permissions).
  4. db.py pushes tenantId/memberId into SQL via sp_set_session_context;
     the stored procedure reads them back out of SESSION_CONTEXT, never as
     parameters.

What's NOT real here: there is no actual "Cobbled platform" issuing tokens
for this course PoC. DSC_STANDALONE_ENABLED turns on a teaching-only
endpoint (/standalone/context, same idea as EDP's) that mints a token for
the single seeded member so the UI has something to send. That endpoint
must never be enabled outside local development - same rule EDP documents
for its own standalone harness.
"""
import os
import time
import uuid
from dataclasses import dataclass, field

import jwt

SIGNING_KEY_BASE64 = os.environ.get("DSC_SECURITY_SIGNING_KEY_BASE64", "")
ISSUER = os.environ.get("DSC_SECURITY_ISSUER", "dsc-standalone")
AUDIENCE = os.environ.get("DSC_SECURITY_AUDIENCE", "dsc-widget")
STANDALONE_ENABLED = os.environ.get("DSC_STANDALONE_ENABLED", "false").lower() == "true"

# Seed identity for the standalone harness - matches sql/no-rls/build.sql's seed data.
DEFAULT_TENANT_ID = "11111111111111111111111111111111"
DEFAULT_MEMBER_ID = "30000000000000000000000000000001"
DEFAULT_AUTHOR_NAME = "Jane"
DEFAULT_THREAD_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

ALL_PERMISSIONS = ["dsc.comments.read", "dsc.comments.write", "dsc.comments.delete"]


@dataclass
class Scope:
    tenant_id: str
    member_id: str
    author_name: str
    permissions: set = field(default_factory=set)

    def has(self, permission: str) -> bool:
        return permission in self.permissions


def _signing_key() -> bytes:
    import base64

    if not SIGNING_KEY_BASE64:
        raise RuntimeError("DSC_SECURITY_SIGNING_KEY_BASE64 is not set.")
    return base64.b64decode(SIGNING_KEY_BASE64)


def read_scope(authorization_header: str | None) -> Scope | None:
    """
    Parses an `Authorization: Bearer <token>` header into a Scope, or
    returns None if the header is missing or the token fails validation.
    Mirrors Program.cs's ReadScopeAsync.
    """
    if not authorization_header or not authorization_header.lower().startswith("bearer "):
        return None
    token = authorization_header[7:]
    try:
        claims = jwt.decode(
            token,
            _signing_key(),
            algorithms=["HS256"],
            issuer=ISSUER,
            audience=AUDIENCE,
            options={"require": ["exp", "iat"]},
            leeway=30,
        )
    except jwt.PyJWTError:
        return None

    tenant_id = claims.get("tenant_id")
    member_id = claims.get("member_id")
    if not isinstance(tenant_id, str) or len(tenant_id) != 32:
        return None
    if not isinstance(member_id, str) or len(member_id) != 32:
        return None

    permissions = claims.get("permissions") or []
    if isinstance(permissions, str):
        permissions = [permissions]

    return Scope(
        tenant_id=tenant_id,
        member_id=member_id,
        author_name=claims.get("author_name") or "Member",
        permissions=set(permissions),
    )


def mint_standalone_token() -> str:
    """
    Dev-only token for the teaching harness - same role as EDP's
    POST /standalone/context. Grants every dsc.comments.* permission to the
    single seeded member; there is no real login flow to check against yet.
    """
    if not STANDALONE_ENABLED:
        raise RuntimeError("Standalone context minting is disabled.")
    now = int(time.time())
    claims = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "iat": now,
        "exp": now + 2 * 60 * 60,
        "jti": uuid.uuid4().hex,
        "tenant_id": DEFAULT_TENANT_ID,
        "member_id": DEFAULT_MEMBER_ID,
        "author_name": DEFAULT_AUTHOR_NAME,
        "permissions": ALL_PERMISSIONS,
    }
    return jwt.encode(claims, _signing_key(), algorithm="HS256")
