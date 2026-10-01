//! Admin controller for user management and system settings (fork extension).

use campfire_db::{Account, CustomSettings, NewUser, Role, Status, User, UserChanges, validate_username};
use campfire_kit::{Ctx, Error, Result, StatusCode, format};
use campfire_views::admin::{AdminUserItem, UsersIndex};
use ruby_compat::integer_cast;

use crate::app::AppCtx;
use crate::concerns::{self, Before};
use crate::controllers::presenters;
use crate::controllers::presenters::page::framed_page;

/// `GET /admin/users`
pub async fn index(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;
    c.respond_to(&[&format::HTML])?;

    let me = concerns::require_current_user(c)?.clone();
    let secrets = c.app().secrets.clone();

    let (join_code, allow_invites, users) = c
        .app()
        .read(move |conn| {
            let account = Account::first(conn)?;
            let join_code = account.map(|a| a.join_code).unwrap_or_default();
            let allow_invites = CustomSettings::is_invite_enabled(conn)?;
            // Query all active and banned non-bot users
            let mut stmt = conn.prepare(
                r#"SELECT * FROM "users" WHERE "status" IN (0, 2) AND "role" != 2 ORDER BY LOWER("name") ASC"#,
            )?;
            let rows = stmt.query_map([], User::from_row)?;
            let mut users = Vec::new();
            for r in rows {
                users.push(r?);
            }
            Ok((join_code, allow_invites, users))
        })
        .await?;

    let user_items: Vec<AdminUserItem> = users
        .into_iter()
        .map(|u| AdminUserItem {
            id: u.id,
            name: u.name.clone(),
            email_address: u.email_address.clone().unwrap_or_default(),
            role: u.role.name().to_string(),
            is_admin: u.role == Role::Administrator,
            is_banned: u.status == Status::Banned,
            is_current_user: u.id == me.id,
            avatar_url: presenters::avatar_path(&secrets, &u),
        })
        .collect();

    framed_page!(c, StatusCode::OK, |ctx| UsersIndex {
        ctx,
        join_code: join_code.clone(),
        allow_invites,
        users: user_items.clone(),
    })
    .await
}

/// `POST /admin/settings/invites`
pub async fn toggle_invites(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    c.app()
        .write(|tx| {
            let current = CustomSettings::is_invite_enabled(tx.conn())?;
            CustomSettings::set_invite_enabled(tx, !current)
        })
        .await?;

    redirect_to_admin(c)
}

/// `POST /admin/users`
pub async fn create_user(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let name = c.params.get("name").and_then(|p| p.to_s()).unwrap_or_default().trim().to_string();
    let email_address = c.params.get("email_address").and_then(|p| p.to_s()).unwrap_or_default().trim().to_string();
    let password = c.params.get("password").and_then(|p| p.to_s()).unwrap_or_default();
    let role = match c.params.get("role").and_then(|p| p.to_s()).as_deref() {
        Some("administrator") => Role::Administrator,
        _ => Role::Member,
    };

    if name.is_empty() {
        return Err(Error::BadRequest("Name cannot be blank".into()));
    }
    if !validate_username(&email_address) {
        return Err(Error::BadRequest("Username must be 1-64 alphanumeric characters (letters, numbers, _, -) or a valid email".into()));
    }
    if password.is_empty() {
        return Err(Error::BadRequest("Password cannot be blank".into()));
    }

    let normalized_username = email_address.to_lowercase();
    let digest = concerns::password_digest(c, Some(password)).await?;

    let attributes = NewUser {
        name,
        email_address: Some(normalized_username),
        password_digest: digest,
        role,
        ..NewUser::default()
    };

    c.app()
        .write(move |tx| {
            User::create(tx, attributes)?;
            Ok(())
        })
        .await?;

    redirect_to_admin(c)
}

/// `POST /admin/users/:id/role`
pub async fn update_role(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let target_id = target_user_id(c)?;
    let current_id = concerns::require_current_user(c)?.id;
    if target_id == current_id {
        return Err(Error::BadRequest("Cannot change your own role".into()));
    }

    let role = match c.params.get("role").and_then(|p| p.to_s()).as_deref() {
        Some("administrator") => Role::Administrator,
        _ => Role::Member,
    };

    c.app()
        .write(move |tx| {
            let mut user = User::find(tx.conn(), target_id)?;
            user.update(tx, UserChanges { role: Some(role), ..UserChanges::default() })
        })
        .await?;

    redirect_to_admin(c)
}

/// `POST /admin/users/:id/reset_password`
pub async fn reset_password(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let target_id = target_user_id(c)?;
    let new_password = c.params.get("new_password")
        .or_else(|| c.params.get("password"))
        .and_then(|p| p.to_s())
        .unwrap_or_default();
    if new_password.is_empty() {
        return Err(Error::BadRequest("Password cannot be blank".into()));
    }

    let digest = concerns::password_digest(c, Some(new_password)).await?
        .ok_or_else(|| Error::internal(anyhow::anyhow!("Password hashing failed")))?;

    c.app()
        .write(move |tx| {
            let mut user = User::find(tx.conn(), target_id)?;
            // Terminate existing sessions so old password cannot remain logged in
            tx.conn().execute(r#"DELETE FROM "sessions" WHERE "sessions"."user_id" = ?"#, [target_id])?;
            user.reset_password(tx, digest)
        })
        .await?;

    redirect_to_admin(c)
}

/// `POST /admin/users/:id/lock`
pub async fn lock_user(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let target_id = target_user_id(c)?;
    let current_id = concerns::require_current_user(c)?.id;
    if target_id == current_id {
        return Err(Error::BadRequest("Cannot lock your own account".into()));
    }

    c.app()
        .write(move |tx| {
            let mut user = User::find(tx.conn(), target_id)?;
            user.lock(tx)
        })
        .await?;

    redirect_to_admin(c)
}

/// `POST /admin/users/:id/unlock`
pub async fn unlock_user(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let target_id = target_user_id(c)?;
    c.app()
        .write(move |tx| {
            let mut user = User::find(tx.conn(), target_id)?;
            user.unlock(tx)
        })
        .await?;

    redirect_to_admin(c)
}

/// `DELETE /admin/users/:id`
pub async fn delete_user(c: &mut Ctx) -> Result {
    concerns::before_actions(c, Before::default()).await?;
    concerns::ensure_can_administer(c)?;

    let target_id = target_user_id(c)?;
    let current_id = concerns::require_current_user(c)?.id;
    if target_id == current_id {
        return Err(Error::BadRequest("Cannot delete your own account".into()));
    }

    c.app()
        .write(move |tx| {
            let mut user = User::find(tx.conn(), target_id)?;
            user.deactivate(tx)
        })
        .await?;

    redirect_to_admin(c)
}

fn target_user_id(c: &Ctx) -> Result<i64> {
    c.param_str("id").and_then(integer_cast).ok_or(Error::NotFound)
}

fn redirect_to_admin(c: &mut Ctx) -> Result {
    let location = c.url_for(&campfire_routes::admin_users());
    c.redirect_to(&location)
}
