import json
import logging

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import db
from .identity import MEMBERS, current_tenant_id, resolve_member
from .models import (
    Comment,
    CommentCreateRequest,
    DeleteResult,
    KarmaEntry,
    VoteRequest,
    VoteResult,
)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("api")

app = FastAPI(
    title="Discussion Thread API",
    description="Discussion Thread microservice PoC — Swagger UI at /docs.",
    version="0.2.0",
)

# The UI is served from a different origin (localhost:8080) than the API
# (localhost:8081); browsers block cross-origin fetches by default.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


class ApiError(Exception):
    def __init__(self, status_code: int, error: str, message: str):
        self.status_code = status_code
        self.error = error
        self.message = message


@app.exception_handler(ApiError)
async def api_error_handler(_request: Request, exc: ApiError):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.error, "message": exc.message},
    )


@app.get("/health")
def health():
    return {"status": "healthy"}


@app.get("/members")
def list_members():
    """
    DEV ONLY. The roster the UI's "viewing as" picker offers. Once JWT is
    wired the caller's identity comes from the token and this disappears.
    """
    return [{"memberId": k, "memberName": v} for k, v in MEMBERS.items()]


@app.get(
    "/threads/{thread_id}/comments",
    response_model=list[Comment],
    status_code=200,
)
def get_comments(thread_id: str, x_member_id: str | None = Header(default=None)):
    tenant_id = current_tenant_id()
    member_id, _ = resolve_member(x_member_id)
    try:
        rows = db.get_comments_by_thread(tenant_id, thread_id, member_id)
    except Exception as exc:  # pragma: no cover - defensive
        log.exception("GetByThread failed")
        raise ApiError(500, "DB_ERROR", str(exc)) from exc
    return rows


@app.post(
    "/threads/{thread_id}/comments",
    response_model=Comment,
    status_code=201,
)
def create_comment(
    thread_id: str,
    payload: CommentCreateRequest,
    x_member_id: str | None = Header(default=None),
):
    tenant_id = current_tenant_id()
    member_id, author_name = resolve_member(x_member_id)
    input_json = json.dumps(
        {
            "body": payload.body,
            "authorName": author_name,
            "parentCommentId": payload.parentCommentId,
        }
    )
    try:
        created = db.create_comment(tenant_id, member_id, thread_id, input_json)
    except Exception as exc:
        msg = str(exc)
        if "50002" in msg or "body is required" in msg:
            raise ApiError(400, "VALIDATION", "body is required.") from exc
        if "50003" in msg or "parentCommentId" in msg:
            raise ApiError(
                404, "NOT_FOUND", "parentCommentId not found, or is itself a reply."
            ) from exc
        log.exception("Create failed")
        raise ApiError(500, "DB_ERROR", msg) from exc
    if not created:
        raise ApiError(500, "DB_ERROR", "Insert did not return a row.")
    return created


@app.put(
    "/threads/{thread_id}/comments/{comment_id}/vote",
    response_model=VoteResult,
    status_code=200,
)
def set_vote(
    thread_id: str,
    comment_id: str,
    payload: VoteRequest,
    x_member_id: str | None = Header(default=None),
):
    """
    Like (1), dislike (-1) or clear (0) this member's vote on a comment.

    PUT rather than POST: a member holds at most one vote per comment, so
    the call sets that vote to a value and is idempotent — sending the same
    value twice leaves the same single row.
    """
    tenant_id = current_tenant_id()
    member_id, _ = resolve_member(x_member_id)
    try:
        result = db.set_comment_vote(
            tenant_id, member_id, comment_id, json.dumps({"value": payload.value})
        )
    except Exception as exc:
        msg = str(exc)
        if "50021" in msg:
            raise ApiError(
                403, "FORBIDDEN", "You cannot vote on your own comment."
            ) from exc
        if "50004" in msg:
            raise ApiError(404, "NOT_FOUND", "Comment not found.") from exc
        if "50020" in msg:
            raise ApiError(
                400, "VALIDATION", "value must be 1, -1 or 0."
            ) from exc
        log.exception("Vote failed")
        raise ApiError(500, "DB_ERROR", msg) from exc
    if not result:
        raise ApiError(500, "DB_ERROR", "Vote did not return a row.")
    return result


@app.get("/karma", response_model=list[KarmaEntry], status_code=200)
def karma_leaderboard():
    """Every member in the tenant who has posted, best karma first."""
    tenant_id = current_tenant_id()
    try:
        return db.list_member_karma(tenant_id)
    except Exception as exc:
        log.exception("Karma list failed")
        raise ApiError(500, "DB_ERROR", str(exc)) from exc


@app.get("/members/{member_id}/karma", response_model=KarmaEntry, status_code=200)
def member_karma(member_id: str):
    tenant_id = current_tenant_id()
    try:
        result = db.get_member_karma(tenant_id, member_id)
    except Exception as exc:
        log.exception("Karma get failed")
        raise ApiError(500, "DB_ERROR", str(exc)) from exc
    if not result:
        raise ApiError(404, "NOT_FOUND", "Member not found in this tenant.")
    return result


@app.delete(
    "/threads/{thread_id}/comments/{comment_id}",
    status_code=204,
)
def delete_comment(
    thread_id: str, comment_id: str, x_member_id: str | None = Header(default=None)
):
    tenant_id = current_tenant_id()
    member_id, _ = resolve_member(x_member_id)
    try:
        result = db.delete_comment(tenant_id, member_id, comment_id)
    except Exception as exc:
        msg = str(exc)

        if "50005" in msg:
            raise ApiError(
                403, "FORBIDDEN", "Only the author can delete their comment."
            ) from exc

        if "50004" in msg:
            raise ApiError(
                404, "NOT_FOUND", "Comment does not exist in this tenant."
            ) from exc

        log.exception("Delete failed")
        raise ApiError(500, "DB_ERROR", msg) from exc
    if result.get("deleted", 0) == 0:
        raise ApiError(404, "NOT_FOUND", "Comment does not exist in this tenant.")
    return None
