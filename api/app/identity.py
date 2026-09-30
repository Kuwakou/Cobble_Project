"""
Tenant/member identity. Per the plan's "decisions to settle before coding":
these come from JWT claims once auth is wired; until then they are
hard-coded constants so nothing above this layer has to be refactored
later. Never accept tenantId / authorMemberId from the request body.

These match the seed data in sql/init/init.sql.
"""

DEFAULT_TENANT_ID = "11111111-1111-1111-1111-111111111111"
DEFAULT_MEMBER_ID = "30000000-0000-0000-0000-000000000001"
DEFAULT_AUTHOR_NAME = "Jane"

# Hard-coded single thread for the PoC (per "Thread scope" decision —
# don't build thread listing).
DEFAULT_THREAD_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

# The roster of members in the seeded tenant. Karma only means something
# when more than one person can vote, so the PoC ships three. When JWT
# lands this whole table goes away: the id and name come from the token.
MEMBERS = {
    "30000000-0000-0000-0000-000000000001": "Jane",
    "30000000-0000-0000-0000-000000000002": "Sam",
    "30000000-0000-0000-0000-000000000003": "Alex",
}


def current_tenant_id() -> str:
    return DEFAULT_TENANT_ID


def resolve_member(override_id: str | None = None) -> tuple[str, str]:
    """
    Returns (memberId, displayName) for the caller.

    DEV ONLY: an X-Member-Id header may name any member in MEMBERS, so the
    board can be exercised as different people without an auth server. An
    unknown or absent value falls back to the default member, so the header
    can never inject an identity that does not exist. This is exactly the
    shape the JWT claim lookup will have, which is why it lives here rather
    than in the route handlers.
    """
    if override_id and override_id in MEMBERS:
        return override_id, MEMBERS[override_id]
    return DEFAULT_MEMBER_ID, MEMBERS[DEFAULT_MEMBER_ID]


def current_member_id(override_id: str | None = None) -> str:
    return resolve_member(override_id)[0]


def current_author_name(override_id: str | None = None) -> str:
    return resolve_member(override_id)[1]
