import logging
from uuid import UUID

from fastapi import FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import db
from .db import DbError
from .identity import STANDALONE_ENABLED, MEMBERS, mint_standalone_token, read_scope
from .models import (
    Comment,
    CommentCreateRequest,
    KarmaEntry,
    ReportedComment,
    ReportRequest,
    ReportResult,
    VoteRequest,
    VoteResult,
)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("api")

app = FastAPI(
    title="Discussion Thread API",
    description="Discussion Thread microservice PoC — Swagger UI at /docs.",
    version="0.3.0",
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


# Maps a DSC_* code (parsed from a THROW in one of the dsc.dsc_*_CRUD_JSON
# procs) onto an HTTP status, the same role Program.cs's error handling
# plays for EDP.
_DB_ERROR_STATUS = {
    "DSC_CONTEXT_REQUIRED": 401,
    "DSC_THREAD_ID_REQUIRED": 400,
    "DSC_BODY_REQUIRED": 400,
    "DSC_PARENT_COMMENT_INVALID": 404,
    "DSC_COMMENT_NOT_FOUND": 404,
    "DSC_COMMENT_FORBIDDEN": 403,
    "DSC_VOTE_VALUE_INVALID": 400,
    "DSC_SELF_VOTE": 400,
    "DSC_REPORT_REASON_REQUIRED": 400,
    "DSC_REPORT_REASON_TOO_LONG": 400,
    "DSC_SELF_REPORT": 400,
    "DSC_ACTION_INVALID": 500,
}


def _raise_from_db_error(exc: DbError):
    status_code = _DB_ERROR_STATUS.get(exc.code, 500)
    raise ApiError(status_code, exc.code, exc.message) from exc


def _require_scope(authorization: str | None):
    scope = read_scope(authorization)
    if scope is None:
        raise ApiError(401, "DSC_UNAUTHENTICATED", "A valid Authorization: Bearer token is required.")
    return scope


def _require_permission(scope, permission: str):
    if not scope.has(permission):
        raise ApiError(
            403,
            "DSC_PERMISSION_REQUIRED",
            f"This action requires the '{permission}' permission.",
        )


@app.get("/health")
def health():
    return {"service": "DSC", "version": "0.3.0", "status": "healthy"}


@app.get("/readiness")
def readiness():
    if db.readiness_ok():
        return {"status": "ready"}
    raise ApiError(503, "DSC_NOT_READY", "dsc.dsc_Comment_CRUD_JSON is not installed yet.")


# Teaching-only harness: mints a token for one of the seeded members so the
# UI has something to send as Authorization: Bearer. Same role as EDP's
# POST /standalone/context, and the same rule applies - DSC_STANDALONE_ENABLED
# must only ever be true in local development. member_id lets the UI's
# "viewing as" picker request a token for whichever seeded member is
# selected; an unknown/omitted id falls back to the default member.
@app.post("/standalone/context")
def standalone_context(member_id: str | None = None):
    if not STANDALONE_ENABLED:
        raise ApiError(404, "DSC_NOT_FOUND", "Not found.")
    return {"token": mint_standalone_token(member_id)}


# Teaching-only: lets the UI build its "viewing as" picker without
# hard-coding the roster client-side.
@app.get("/members")
def list_members():
    if not STANDALONE_ENABLED:
        raise ApiError(404, "DSC_NOT_FOUND", "Not found.")
    return [{"memberId": member_id, "memberName": name} for member_id, name in MEMBERS.items()]


@app.get(
    "/threads/{thread_id}/comments",
    response_model=list[Comment],
    status_code=200,
)
def get_comments(thread_id: UUID, authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.read")
    try:
        rows = db.list_comments(scope, thread_id.hex)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:  # pragma: no cover - defensive
        log.exception("List failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    return rows


@app.post(
    "/threads/{thread_id}/comments",
    response_model=Comment,
    status_code=201,
)
def create_comment(
    thread_id: UUID,
    payload: CommentCreateRequest,
    authorization: str | None = Header(default=None),
):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.write")
    try:
        created = db.create_comment(scope, thread_id.hex, payload.body, payload.parentCommentId)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Create failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    if not created:
        raise ApiError(500, "DSC_DB_ERROR", "Insert did not return a row.")
    return created


@app.delete(
    "/threads/{thread_id}/comments/{comment_id}",
    status_code=204,
)
def delete_comment(thread_id: UUID, comment_id: UUID, authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.delete")
    try:
        db.delete_comment(scope, thread_id.hex, comment_id.hex)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Delete failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    return None


@app.put(
    "/threads/{thread_id}/comments/{comment_id}/vote",
    response_model=VoteResult,
    status_code=200,
)
def set_vote(
    thread_id: UUID,
    comment_id: UUID,
    payload: VoteRequest,
    authorization: str | None = Header(default=None),
):
    # Both ids are typed as UUID (FastAPI 422s on anything malformed before
    # this body runs) and both are passed through to the proc together, so
    # a comment_id from a different thread than the one in the URL is
    # rejected as DSC_COMMENT_NOT_FOUND rather than silently voting on it.
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.votes.write")
    try:
        result = db.set_vote(scope, thread_id.hex, comment_id.hex, payload.value)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Vote failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    if not result:
        raise ApiError(500, "DSC_DB_ERROR", "Vote did not return a row.")
    return result


@app.get(
    "/karma",
    response_model=list[KarmaEntry],
    status_code=200,
)
def get_karma_leaderboard(authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.karma.read")
    try:
        rows = db.list_karma(scope)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Karma list failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    return rows


@app.get(
    "/members/{member_id}/karma",
    response_model=KarmaEntry,
    status_code=200,
)
def get_member_karma(member_id: UUID, authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.karma.read")
    try:
        result = db.get_member_karma(scope, member_id.hex)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Karma get failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    if not result:
        raise ApiError(500, "DSC_DB_ERROR", "Karma lookup did not return a row.")
    return result


@app.put(
    "/threads/{thread_id}/comments/{comment_id}/report",
    response_model=ReportResult,
    status_code=200,
)
def report_comment(
    thread_id: UUID,
    comment_id: UUID,
    payload: ReportRequest,
    authorization: str | None = Header(default=None),
):
    # Same fix as /vote above (this is the exact pair of bugs Ali flagged
    # in review): thread_id and comment_id are both UUID-typed, so a
    # malformed id 422s instead of reaching SQL, and both are validated
    # together against the comment's real thread rather than thread_id
    # being accepted and then ignored.
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.reports.write")
    try:
        result = db.set_report(scope, thread_id.hex, comment_id.hex, payload.reason)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Report failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    if not result:
        raise ApiError(500, "DSC_DB_ERROR", "Report did not return a row.")
    return result


@app.get(
    "/reports",
    response_model=list[ReportedComment],
    status_code=200,
)
def list_reports(authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.reports.read")
    try:
        rows = db.list_reports(scope)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Report list failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    return rows
