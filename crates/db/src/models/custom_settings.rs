//! Key-value store for app settings added by fork extensions.
//! Stored in the `custom_settings` table to avoid conflicts with upstream schema.

use rusqlite::{Connection, OptionalExtension, params};
use crate::database::Tx;
use crate::error::Result;
use crate::sql::CachedStatements;

pub const KEY_ALLOW_INVITES: &str = "allow_invites";

pub struct CustomSettings;

impl CustomSettings {
    pub fn get(conn: &Connection, key: &str) -> Result<Option<String>> {
        let value: Option<String> = conn
            .query_row(
                r#"SELECT "value" FROM "custom_settings" WHERE "key" = ? LIMIT 1"#,
                [key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(value)
    }

    pub fn set(tx: &mut Tx<'_>, key: &str, value: &str) -> Result<()> {
        tx.conn().execute_cached(
            r#"INSERT INTO "custom_settings" ("key", "value") VALUES (?, ?)
               ON CONFLICT("key") DO UPDATE SET "value" = excluded."value""#,
            params![key, value],
        )?;
        Ok(())
    }

    pub fn is_invite_enabled(conn: &Connection) -> Result<bool> {
        let val = Self::get(conn, KEY_ALLOW_INVITES)?;
        match val.as_deref() {
            Some("false") | Some("0") | Some("off") => Ok(false),
            _ => Ok(true),
        }
    }

    pub fn set_invite_enabled(tx: &mut Tx<'_>, enabled: bool) -> Result<()> {
        Self::set(tx, KEY_ALLOW_INVITES, if enabled { "true" } else { "false" })
    }
}

use crate::models::user::{PasswordDigest, Status, User, UserChanges};

impl User {
    /// Lock user: disconnect sockets and revoke sessions without deleting message history.
    pub fn lock(&mut self, tx: &mut Tx<'_>) -> Result<()> {
        tx.emit_after_commit(crate::events::Event::DisconnectUser { user_id: self.id, reconnect: false });
        tx.conn().execute_cached(r#"DELETE FROM "sessions" WHERE "sessions"."user_id" = ?"#, [self.id])?;
        self.update(tx, UserChanges { status: Some(Status::Banned), ..Default::default() })
    }

    /// Unlock user: restore active status.
    pub fn unlock(&mut self, tx: &mut Tx<'_>) -> Result<()> {
        tx.conn().execute_cached(r#"DELETE FROM "bans" WHERE "bans"."user_id" = ?"#, [self.id])?;
        self.update(tx, UserChanges { status: Some(Status::Active), ..Default::default() })
    }

    /// Reset password digest.
    pub fn reset_password(&mut self, tx: &mut Tx<'_>, digest: PasswordDigest) -> Result<()> {
        self.update(tx, UserChanges { password_digest: Some(digest), ..Default::default() })
    }
}

/// Validate username or email: allows 1..=64 characters of [a-zA-Z0-9_-] or a valid email address.
pub fn validate_username(input: &str) -> bool {
    let s = input.trim();
    if s.is_empty() || s.len() > 64 {
        return false;
    }
    if s.contains('@') {
        let parts: Vec<&str> = s.split('@').collect();
        parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty() && parts[1].contains('.')
    } else {
        s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    }
}

