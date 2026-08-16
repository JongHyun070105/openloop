import json
import sqlite3
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path

from .models import OpenLoop


class LoopRepository:
    def __init__(self, database_path: str | Path) -> None:
        self.database_path = str(database_path)
        self._connection_uri = self.database_path.startswith("file:")
        if not self._connection_uri and self.database_path != ":memory:":
            Path(self.database_path).parent.mkdir(parents=True, exist_ok=True)
        self._keeper: sqlite3.Connection | None = None
        if self.database_path == ":memory:":
            self.database_path = "file:openloop-memory?mode=memory&cache=shared"
            self._connection_uri = True
            self._keeper = self._connect()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, uri=self._connection_uri)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize(self) -> None:
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS loops (
                    id TEXT PRIMARY KEY,
                    status TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    delete_at TEXT,
                    document TEXT NOT NULL
                )
                """
            )
            connection.execute("CREATE INDEX IF NOT EXISTS loops_status_idx ON loops(status)")

    def close(self) -> None:
        """Release the keeper connection used only by the shared in-memory database."""

        if self._keeper is not None:
            self._keeper.close()
            self._keeper = None

    def _purge_expired(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            "DELETE FROM loops WHERE delete_at IS NOT NULL AND delete_at <= ?",
            (datetime.now(UTC).isoformat(),),
        )

    def save(self, loop: OpenLoop) -> OpenLoop:
        with closing(self._connect()) as connection, connection:
            self._purge_expired(connection)
            connection.execute(
                """INSERT INTO loops(id, status, updated_at, delete_at, document)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET status=excluded.status,
                       updated_at=excluded.updated_at, delete_at=excluded.delete_at,
                       document=excluded.document""",
                (
                    loop.id,
                    loop.status.value,
                    loop.updated_at.isoformat(),
                    loop.delete_at.isoformat() if loop.delete_at else None,
                    loop.model_dump_json(),
                ),
            )
        return loop

    def get(self, loop_id: str) -> OpenLoop | None:
        with closing(self._connect()) as connection, connection:
            self._purge_expired(connection)
            row = connection.execute("SELECT document FROM loops WHERE id = ?", (loop_id,)).fetchone()
        return OpenLoop.model_validate(json.loads(row["document"])) if row else None

    def list(self, status: str | None = None) -> list[OpenLoop]:
        with closing(self._connect()) as connection, connection:
            self._purge_expired(connection)
            if status:
                rows = connection.execute(
                    "SELECT document FROM loops WHERE status = ? ORDER BY updated_at DESC", (status,)
                ).fetchall()
            else:
                rows = connection.execute("SELECT document FROM loops ORDER BY updated_at DESC").fetchall()
        return [OpenLoop.model_validate(json.loads(row["document"])) for row in rows]

    def delete(self, loop_id: str) -> bool:
        with closing(self._connect()) as connection, connection:
            cursor = connection.execute("DELETE FROM loops WHERE id = ?", (loop_id,))
        return cursor.rowcount > 0
