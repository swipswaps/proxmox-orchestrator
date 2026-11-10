import sqlite3, os
DB_PATH = os.getenv("DATABASE_PATH", "/app/data/orchestrator.db")
def get_db_connection():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn
def init_db():
    conn = get_db_connection()
    with conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS deployments (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            type TEXT NOT NULL CHECK(type IN ('lxc','vm')),
            target_node TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    conn.close()
