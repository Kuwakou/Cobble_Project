from datetime import datetime
from typing import Literal, Optional

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
    likes: int = 0
    dislikes: int = 0
    score: int = 0
    myVote: int = 0
    authorKarma: int = 0


class CommentCreateRequest(BaseModel):
    body: str = Field(..., min_length=1)
    parentCommentId: Optional[str] = None


class DeleteResult(BaseModel):
    deleted: int


class VoteRequest(BaseModel):
    value: Literal[-1, 0, 1]


class VoteResult(BaseModel):
    commentId: str
    authorMemberId: str
    likes: int
    dislikes: int
    score: int
    myVote: int
    authorKarma: int


class KarmaEntry(BaseModel):
    memberId: str
    memberName: str
    commentCount: int
    likesReceived: int = 0
    dislikesReceived: int = 0
    karma: int


class ReportRequest(BaseModel):
    reason: str = Field(..., min_length=1, max_length=500)


class ReportResult(BaseModel):
    commentId: str
    authorMemberId: str
    reportCount: int
    myReport: int
    myReason: Optional[str] = None


class ReportedComment(BaseModel):
    commentId: str
    threadId: str
    authorMemberId: str
    authorName: str
    body: str
    isDeleted: bool
    reportCount: int
    lastReportedUtc: datetime


class ErrorResponse(BaseModel):
    error: str
    message: str
