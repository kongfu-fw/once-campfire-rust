//! Pinned messages: stores at most 1 pinned message per room.
//! Fork extension table in `pinned_messages`.

use crate::database::Tx;
use crate::error::Result;
use crate::sql::CachedStatements;
use crate::time::Timestamp;
use rusqlite::{Connection, OptionalExtension, params};

#[derive(Debug, Clone, PartialEq)]
pub struct PinnedMessage {
    pub room_id: i64,
    pub message_id: i64,
    pub pinned_by_id: i64,
    pub pinned_at: Timestamp,
}

impl PinnedMessage {
    pub fn find_for_room(conn: &Connection, room_id: i64) -> Result<Option<Self>> {
        let row = conn
            .query_row(
                r#"SELECT "room_id", "message_id", "pinned_by_id", "pinned_at"
                   FROM "pinned_messages"
                   WHERE "room_id" = ? LIMIT 1"#,
                [room_id],
                |r| Ok(Self { room_id: r.get(0)?, message_id: r.get(1)?, pinned_by_id: r.get(2)?, pinned_at: r.get(3)? }),
            )
            .optional()?;
        Ok(row)
    }

    pub fn pin(tx: &mut Tx<'_>, room_id: i64, message_id: i64, pinned_by_id: i64, pinned_at: Timestamp) -> Result<Self> {
        tx.conn().execute_cached(
            r#"INSERT INTO "pinned_messages" ("room_id", "message_id", "pinned_by_id", "pinned_at")
               VALUES (?, ?, ?, ?)
               ON CONFLICT("room_id") DO UPDATE SET
                 "message_id" = excluded."message_id",
                 "pinned_by_id" = excluded."pinned_by_id",
                 "pinned_at" = excluded."pinned_at""#,
            params![room_id, message_id, pinned_by_id, pinned_at],
        )?;
        Ok(Self { room_id, message_id, pinned_by_id, pinned_at })
    }

    pub fn unpin(tx: &mut Tx<'_>, room_id: i64) -> Result<bool> {
        let rows = tx.conn().execute_cached(r#"DELETE FROM "pinned_messages" WHERE "room_id" = ?"#, [room_id])?;
        Ok(rows > 0)
    }

    pub fn is_pinned(conn: &Connection, message_id: i64) -> Result<bool> {
        let exists: Option<i64> =
            conn.query_row(r#"SELECT 1 FROM "pinned_messages" WHERE "message_id" = ? LIMIT 1"#, [message_id], |r| r.get(0)).optional()?;
        Ok(exists.is_some())
    }
}
