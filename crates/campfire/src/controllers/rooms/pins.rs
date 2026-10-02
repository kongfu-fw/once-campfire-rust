//! Pinned messages controller for open and closed rooms.

use askama::Template;
use campfire_db::{Message, PinnedMessage, Timestamp, User};
use campfire_kit::{Ctx, Error, Result, StatusCode, halt};
use ruby_compat::integer_cast;

use crate::app::{App, AppCtx};
use crate::concerns::{self, Before, before_actions, require_current_user};
use crate::controllers::presenters::Presenter;
use crate::controllers::presenters::page;
use crate::controllers::rooms::{Scope, set_room};

/// POST /rooms/:room_id/pin
pub async fn create(c: &mut Ctx) -> Result {
    before_actions(c, Before::default()).await?;
    let user = require_current_user(c)?.clone();
    if !user.is_administrator() {
        return halt(concerns::head(StatusCode::FORBIDDEN));
    }
    let room = set_room(c, Scope::WithoutDirects).await?;
    let message_id = c.param_str("message_id").and_then(integer_cast).ok_or_else(|| Error::BadRequest("message_id required".into()))?;

    let app = c.app().clone();
    let request_host = Some(c.request.host());
    let (room_for_read, app_for_read) = (room.clone(), app.clone());

    // 1. Verify message belongs to room
    c.app()
        .read(move |conn| {
            let message = Message::find_by_id(conn, message_id)?
                .filter(|m| m.room_id == room_for_read.id)
                .ok_or_else(|| campfire_db::Error::RecordNotFound("Message"))?;
            Ok(message)
        })
        .await?;

    // 2. Persist the pin
    let now = c.clock().now();
    let pinned_by_id = user.id;
    let room_id = room.id;
    let pinned = c.app().write(move |tx| PinnedMessage::pin(tx, room_id, message_id, pinned_by_id, Timestamp::from_jiff(now))).await?;

    // 3. Render partial for broadcast
    let base_url = page::renderer_base_url(c);
    let html = c
        .app()
        .read(move |conn| {
            let pinned_view = build_pinned_view(conn, &app_for_read, request_host, &pinned)?;
            let account = campfire_db::Account::first(conn)?;
            page::render_detached_at(&app_for_read, account.as_ref(), &base_url, |ctx| {
                campfire_views::rooms::PinnedMessagePartial { ctx, pinned: pinned_view.as_ref(), room_id }.render()
            })
            .map_err(campfire_db::Error::other)
        })
        .await?;

    // 4. Broadcast to all users in the room
    c.app().broadcasts.pinned_message_update(&room, &html);

    Ok(c.head(StatusCode::NO_CONTENT))
}

/// DELETE /rooms/:room_id/pin
pub async fn destroy(c: &mut Ctx) -> Result {
    before_actions(c, Before::default()).await?;
    let user = require_current_user(c)?;
    if !user.is_administrator() {
        return halt(concerns::head(StatusCode::FORBIDDEN));
    }
    let room = set_room(c, Scope::WithoutDirects).await?;
    let room_id = room.id;

    c.app().write(move |tx| PinnedMessage::unpin(tx, room_id)).await?;

    // Broadcast removal
    c.app().broadcasts.pinned_message_remove(&room);

    Ok(c.head(StatusCode::NO_CONTENT))
}

/// Helper to build PinnedMessageView
pub fn build_pinned_view(
    conn: &campfire_db::Connection,
    app: &App,
    request_host: Option<String>,
    pinned: &PinnedMessage,
) -> campfire_db::Result<Option<campfire_views::rooms::PinnedMessageView>> {
    let Some(message) = Message::find_by_id(conn, pinned.message_id)? else {
        return Ok(None);
    };
    let pinned_by_name = User::find_by_id(conn, pinned.pinned_by_id)?.map(|u| u.name).unwrap_or_else(|| "管理员".to_string());

    let presenter = Presenter::new(conn, app, request_host);
    let view = presenter.message(&message)?;

    let (summary_emoji, summary_text) = match &view.content {
        campfire_views::messages::MessageContent::Attachment(att) => {
            let emoji = match &att.preview {
                campfire_views::messages::AttachmentPreview::Image { .. } => "📷",
                campfire_views::messages::AttachmentPreview::Video { .. } => "🎬",
                campfire_views::messages::AttachmentPreview::VoiceMessage { .. } => "🎵",
                campfire_views::messages::AttachmentPreview::File => "📁",
            };
            (Some(emoji.to_string()), String::new())
        }
        campfire_views::messages::MessageContent::Sound(_) => (Some("🎵".to_string()), String::new()),
        campfire_views::messages::MessageContent::Text { html } => {
            let plain = strip_html_tags(html);
            let snippet = if plain.chars().count() > 60 {
                let s: String = plain.chars().take(60).collect();
                format!("{s}...")
            } else {
                plain
            };
            (None, snippet)
        }
        campfire_views::messages::MessageContent::Unrenderable => (None, "无法渲染的消息".to_string()),
    };

    Ok(Some(campfire_views::rooms::PinnedMessageView {
        room_id: pinned.room_id,
        message_id: pinned.message_id,
        client_message_id: message.client_message_id,
        pinned_by_name,
        pinned_at: pinned.pinned_at.jiff(),
        summary_emoji,
        summary_text,
        message: Box::new(view),
    }))
}

fn strip_html_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut inside = false;
    for c in html.chars() {
        match c {
            '<' => inside = true,
            '>' => inside = false,
            _ if !inside => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}
