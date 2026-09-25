from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class Comment(BaseModel):
    commentId: str
    threadId: str
    tenantId: str
    authorMemberId: str
    authorName: str
    body: str
    parentCommentId: Optional[str] = None
    createdUtc: datetime


class CommentCreateRequest(BaseModel):
    body: str = Field(..., min_length=1)
    parentCommentId: Optional[str] = None


class DeleteResult(BaseModel):
    deleted: int


class ErrorResponse(BaseModel):
    error: str
    message: str
