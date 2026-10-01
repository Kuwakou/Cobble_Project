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
    # Vote tallies. likes - dislikes = score. myVote is the calling member's
    # own vote on this comment (1, -1 or 0), so the UI can show a button as
    # already pressed. authorKarma is the author's net karma across the board.
    likes: int = 0
    dislikes: int = 0
    score: int = 0
    myVote: int = 0
    authorKarma: int = 0


class CommentCreateRequest(BaseModel):
    body: str = Field(..., min_length=1)
    parentCommentId: Optional[str] = None


class VoteRequest(BaseModel):
    # 1 = like, -1 = dislike, 0 = clear my vote. Pressing an already-active
    # button sends 0, which is how the UI implements toggle-off.
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
    likesReceived: int
    dislikesReceived: int
    karma: int


class DeleteResult(BaseModel):
    deleted: int


class ErrorResponse(BaseModel):
    error: str
    message: str
