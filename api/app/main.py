import logging

from fastapi import FastAPI, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import db
from .db import DbError
from .identity import STANDALONE_ENABLED, mint_standalone_token, read_scope
from .models import Comment, CommentCreateRequest

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


# Maps a DSC_* code (parsed from a THROW in dsc.dsc_Comment_CRUD_JSON) onto an
# HTTP status, the same role Program.cs's error handling plays for EDP.
_DB_ERROR_STATUS = {
    "DSC_CONTEXT_REQUIRED": 401,
    "DSC_THREAD_ID_REQUIRED": 400,
    "DSC_BODY_REQUIRED": 400,
    "DSC_PARENT_COMMENT_INVALID": 404,
    "DSC_COMMENT_NOT_FOUND": 404,
    "DSC_COMMENT_FORBIDDEN": 403,
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
    return {"service": "DSC", "version": "0.2.0", "status": "healthy"}


@app.get("/readiness")
def readiness():
    if db.readiness_ok():
        return {"status": "ready"}
    raise ApiError(503, "DSC_NOT_READY", "dsc.dsc_Comment_CRUD_JSON is not installed yet.")


# Teaching-only harness: mints a token for the single seeded member so the
# UI has something to send as Authorization: Bearer. Same role as EDP's
# POST /standalone/context, and the same rule applies - DSC_STANDALONE_ENABLED
# must only ever be true in local development.
@app.post("/standalone/context")
def standalone_context():
    if not STANDALONE_ENABLED:
        raise ApiError(404, "DSC_NOT_FOUND", "Not found.")
    return {"token": mint_standalone_token()}


@app.get(
    "/threads/{thread_id}/comments",
    response_model=list[Comment],
    status_code=200,
)
def get_comments(thread_id: str, authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.read")
    try:
        rows = db.list_comments(scope, thread_id)
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
    thread_id: str,
    payload: CommentCreateRequest,
    authorization: str | None = Header(default=None),
):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.write")
    try:
        created = db.create_comment(scope, thread_id, payload.body, payload.parentCommentId)
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
def delete_comment(thread_id: str, comment_id: str, authorization: str | None = Header(default=None)):
    scope = _require_scope(authorization)
    _require_permission(scope, "dsc.comments.delete")
    try:
        db.delete_comment(scope, comment_id)
    except DbError as exc:
        _raise_from_db_error(exc)
    except Exception as exc:
        log.exception("Delete failed")
        raise ApiError(500, "DSC_DB_ERROR", str(exc)) from exc
    return None
