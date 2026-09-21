"""
Tenant/member identity. Per the plan's "decisions to settle before coding":
these come from JWT claims once auth is wired; until then they are
hard-coded constants so nothing above this layer has to be refactored
later. Never accept tenantId / authorMemberId from the request body.

These match the seed data in db/init.sql.
"""

DEFAULT_TENANT_ID = "11111111-1111-1111-1111-111111111111"
DEFAULT_MEMBER_ID = "30000000-0000-0000-0000-000000000001"
DEFAULT_AUTHOR_NAME = "Jane"

# Hard-coded single thread for the PoC (per "Thread scope" decision —
# don't build thread listing).
DEFAULT_THREAD_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"


def current_tenant_id() -> str:
    return DEFAULT_TENANT_ID


def current_member_id() -> str:
    return DEFAULT_MEMBER_ID


def current_author_name() -> str:
    return DEFAULT_AUTHOR_NAME
