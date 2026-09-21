from datetime import datetime

from pydantic import BaseModel, Field


class Comment(BaseModel):
    commentId: str
    threadId: str
    tenantId: str
    authorMemberId: str
    authorName: str
    body: str
    createdUtc: datetime


class CommentCreateRequest(BaseModel):
    body: str = Field(..., min_length=1)


class DeleteResult(BaseModel):
    deleted: int


class ErrorResponse(BaseModel):
    error: str
    message: str
