"""
Thin data-access layer, mirroring Program.cs's ExecuteCrudAsync in the
Cobbled EDP reference module.

The API never writes SELECT/INSERT/UPDATE/DELETE against tables directly -
it only EXECs dsc.dsc_Comment_CRUD_JSON (sql/no-rls/build.sql or
sql/rls/build.sql), and the identity it hands that proc comes from the
caller's validated Scope, pushed into the connection via
sys.sp_set_session_context - never as explicit stored-procedure parameters,
and never from the request body.
"""
import json
import os
import re

import pymssql

from .identity import Scope

SQL_SERVER = os.environ.get("SQL_SERVER", "sql")
SQL_DATABASE = os.environ.get("SQL_DATABASE", "DiscussionPoC")
SQL_USER = os.environ.get("SQL_USER", "sa")
SQL_PASSWORD = os.environ["SQL_PASSWORD"]

_DSC_CODE = re.compile(r"\bDSC_[A-Z_]+\b")


class DbError(Exception):
    """Raised when the proc THROWs. .code is the DSC_* token from the message, if any."""

    def __init__(self, message: str):
        match = _DSC_CODE.search(message)
        self.code = match.group(0) if match else "DSC_UNKNOWN"
        self.message = message
        super().__init__(message)


def _connect():
    return pymssql.connect(
        server=SQL_SERVER,
        user=SQL_USER,
        password=SQL_PASSWORD,
        database=SQL_DATABASE,
        as_dict=False,
        autocommit=True,
    )


def _exec_crud(scope: Scope, action: str, payload: dict):
    """
    Sets TenantID/MemberID into SESSION_CONTEXT for this connection, then
    calls dsc.dsc_Comment_CRUD_JSON. SQL Server splits a long FOR JSON
    result across multiple rows/columns, so every row's single column is
    concatenated before parsing (same quirk as before).
    """
    conn = _connect()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "EXEC sys.sp_set_session_context @key=%s, @value=%s",
            ("TenantID", scope.tenant_id),
        )
        cursor.execute(
            "EXEC sys.sp_set_session_context @key=%s, @value=%s",
            ("MemberID", scope.member_id),
        )
        try:
            cursor.execute(
                "EXEC dsc.dsc_Comment_CRUD_JSON @Action=%s, @Payload=%s",
                (action, json.dumps(payload)),
            )
        except pymssql.Error as exc:
            raise DbError(str(exc)) from exc

        chunks = []
        for row in cursor.fetchall():
            if row and row[0] is not None:
                chunks.append(row[0])
        raw = "".join(chunks)
        return json.loads(raw) if raw else None
    finally:
        conn.close()


def readiness_ok() -> bool:
    """Diagnostic existence check only - mirrors EDP's /readiness probe
    (SELECT IIF(OBJECT_ID(...) IS NULL,0,1)). Not a business-data query, so
    this is the one place this module is allowed to run SQL that isn't a
    call to dsc.dsc_Comment_CRUD_JSON."""
    try:
        conn = _connect()
        try:
            cursor = conn.cursor()
            cursor.execute(
                "SELECT CASE WHEN OBJECT_ID(N'dsc.dsc_Comment_CRUD_JSON', N'P') IS NULL THEN 0 ELSE 1 END"
            )
            row = cursor.fetchone()
            return bool(row and row[0] == 1)
        finally:
            conn.close()
    except pymssql.Error:
        return False


def list_comments(scope: Scope, thread_id: str):
    result = _exec_crud(scope, "SELECT", {"threadId": thread_id})
    return result or []


def create_comment(scope: Scope, thread_id: str, body: str, parent_comment_id: str | None):
    return _exec_crud(
        scope,
        "INSERT",
        {
            "threadId": thread_id,
            "body": body,
            "authorName": scope.author_name,
            "parentCommentId": parent_comment_id,
        },
    )


def delete_comment(scope: Scope, comment_id: str):
    return _exec_crud(scope, "DELETE", {"commentId": comment_id})
