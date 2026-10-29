# UIDHUB — XeroxUID Slate V8

Railway deployment repository for XeroxUID Slate V8.

**Important:** The full application source is in the prepared ZIP provided in this conversation. Extract that ZIP into the repository root (not a nested xeroxuid directory), then commit. The web process is `gunicorn --bind 0.0.0.0:$PORT app:app`.

Do not expose default admin credentials. The original application uses SQLite; PostgreSQL support requires code migration and cannot be enabled by setting DATABASE_URL alone.
