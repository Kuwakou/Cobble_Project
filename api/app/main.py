import json
import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from . import db
from .identity import current_author_name, current_member_id, current_tenant_id
from .models import Comment, CommentCreateRequest, DeleteResult

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("api")

app = FastAPI(
    title="Discussion Thread API",
    description="Discussion Thread microservice PoC — Swagger UI at /docs.",
    version="0.1.0",
)

# The UI is served from a different origin (localhost:3000) than the API
# (localhost:8080); browsers block cross-origin fetches by default.
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


@app.get(
    "/threads/{thread_id}/comments",
    response_model=list[Comment],
    status_code=200,
)
def get_comments(thread_id: str):
    tenant_id = current_tenant_id()
    try:
        rows = db.get_comments_by_thread(tenant_id, thread_id)
    except Exception as exc:  # pragma: no cover - defensive
        log.exception("GetByThread failed")
        raise ApiError(500, "DB_ERROR", str(exc)) from exc
    return rows


@app.post(
    "/threads/{thread_id}/comments",
    response_model=Comment,
    status_code=201,
)
def create_comment(thread_id: str, payload: CommentCreateRequest):
    tenant_id = current_tenant_id()
    member_id = current_member_id()
    input_json = json.dumps(
        {"body": payload.body, "authorName": current_author_name()}
    )
    try:
        created = db.create_comment(tenant_id, member_id, thread_id, input_json)
    except Exception as exc:
        msg = str(exc)
        if "50002" in msg or "body is required" in msg:
            raise ApiError(400, "VALIDATION", "body is required.") from exc
        log.exception("Create failed")
        raise ApiError(500, "DB_ERROR", msg) from exc
    if not created:
        raise ApiError(500, "DB_ERROR", "Insert did not return a row.")
    return created


@app.delete(
    "/threads/{thread_id}/comments/{comment_id}",
    status_code=204,
)
def delete_comment(thread_id: str, comment_id: str):
    tenant_id = current_tenant_id()
    member_id = current_member_id()
    try:
        result = db.delete_comment(tenant_id, member_id, comment_id)
    except Exception as exc:
        log.exception("Delete failed")
        raise ApiError(500, "DB_ERROR", str(exc)) from exc
    if result.get("deleted", 0) == 0:
        raise ApiError(404, "NOT_FOUND", "Comment does not exist in this tenant.")
    return None
