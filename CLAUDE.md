# perspective-cuts

A text-based Apple Shortcuts compiler.

## Rules

- **Always open SQLite databases read-only** (`SQLITE_OPEN_READONLY` / `sqlite3_open_v2` with read-only flag). Never open with write access unless the operation explicitly requires it (e.g., `--install` writing to the Shortcuts database).
