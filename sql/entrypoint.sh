#!/bin/bash
# Starts SQL Server, waits until startup recovery is complete, then applies every script in
# /usr/src/app/init in lexical order. All scripts are idempotent, so this runs on every start.
set -u
/opt/mssql/bin/sqlservr &
PID=$!

SQLCMD="/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P $MSSQL_SA_PASSWORD -C -b -I"
# Ready = the current error log contains "Recovery is complete" (all databases recovered).
READY="DECLARE @t TABLE (LogDate DATETIME, ProcessInfo NVARCHAR(50), [Text] NVARCHAR(MAX)); INSERT @t EXEC xp_readerrorlog 0, 1, N'Recovery is complete'; IF NOT EXISTS (SELECT 1 FROM @t) THROW 50000, 'recovering', 1;"

for i in $(seq 1 90); do
  if $SQLCMD -Q "$READY" > /dev/null 2>&1; then
    echo "[init] SQL Server recovery complete after ${i} probe(s)"
    for attempt in 1 2 3; do
      ok=1
      for f in /usr/src/app/init/*.sql; do
        if $SQLCMD -v ApiPassword="$API_DB_PASSWORD" -i "$f"; then
          echo "[init] applied $(basename "$f")"
        else
          echo "[init] FAILED $(basename "$f") (attempt $attempt)"; ok=0; break
        fi
      done
      if [ "$ok" = 1 ]; then echo "[init] done - all scripts applied"; break; fi
      sleep 5
    done
    [ "$ok" = 1 ] || echo "[init] done WITH FAILURES"
    break
  fi
  sleep 2
done

wait $PID
