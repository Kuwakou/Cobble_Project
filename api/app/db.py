"""
Thin data-access layer. The API never writes SELECT/INSERT/UPDATE/DELETE
against tables directly — it only EXECs the stored procedures agreed in
section 1.3 / 4 of the build plan, and passes the JSON straight through.
"""
import json
import os

import pymssql

SQL_SERVER = os.environ.get("SQL_SERVER", "sql")
SQL_DATABASE = os.environ.get("SQL_DATABASE", "DiscussionPoC")
SQL_USER = os.environ.get("SQL_USER", "sa")
SQL_PASSWORD = os.environ["SQL_PASSWORD"]


def _connect():
    return pymssql.connect(
        server=SQL_SERVER,
        user=SQL_USER,
        password=SQL_PASSWORD,
        database=SQL_DATABASE,
        as_dict=False,
        autocommit=True,
    )


def _exec_json_proc(proc_name: str, params: tuple):
    """
    Calls a stored procedure that returns its result via
    `FOR JSON PATH` (or `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER`).
    SQL Server splits a long JSON result across multiple rows/columns
    (the classic FOR JSON quirk), so every row's single column is
    concatenated before parsing.
    """
    conn = _connect()
    try:
        cursor = conn.cursor()
        placeholders = ", ".join(["%s"] * len(params))
        cursor.execute(f"EXEC {proc_name} {placeholders}", params)
        chunks = []
        for row in cursor.fetchall():
            if row and row[0] is not None:
                chunks.append(row[0])
        raw = "".join(chunks)
        return json.loads(raw) if raw else None
    finally:
        conn.close()


def get_comments_by_thread(tenant_id: str, thread_id: str):
    result = _exec_json_proc(
        "dsc.Comments_GetByThread_JSON", (tenant_id, thread_id)
    )
    return result or []


def create_comment(tenant_id: str, member_id: str, thread_id: str, body_json: str):
    return _exec_json_proc(
        "dsc.Comments_Create_JSON", (tenant_id, member_id, thread_id, body_json)
    )


def delete_comment(tenant_id: str, member_id: str, comment_id: str):
    result = _exec_json_proc(
        "dsc.Comments_Delete_JSON", (tenant_id, member_id, comment_id)
    )
    return result or {"deleted": 0}
