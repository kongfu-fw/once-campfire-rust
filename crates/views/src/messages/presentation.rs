//! `MessagesHelper#message_presentation` and `Messages::AttachmentPresentation`
//! (`reference/app/helpers/messages_helper.rb`, `reference/app/helpers/messages/attachment_presentation.rb`).

use crate::ViewContext;
use crate::helpers::escape;

use super::support::RubyNumber;
use super::{AttachmentPreview, AttachmentView, MessageContent, MessageView, SoundView};

/// `Message::THUMBNAIL_MAX_WIDTH` / `THUMBNAIL_MAX_HEIGHT`.
const THUMBNAIL_MAX_WIDTH: i64 = 1200;
const THUMBNAIL_MAX_HEIGHT: i64 = 800;

/// `message_presentation(message)`.
pub fn message_presentation(ctx: &ViewContext, message: &MessageView) -> String {
    match &message.content {
        MessageContent::Attachment(attachment) => attachment_presentation(ctx, attachment),
        MessageContent::Sound(sound) => sound_presentation(sound),
        MessageContent::Text { html } => html.clone(),
        // `messages/_message` renders `messages/_unrenderable` instead.
        MessageContent::Unrenderable => String::new(),
    }
}

/// `message_sound_presentation`: a play button followed by the sound's image or text.
fn sound_presentation(sound: &SoundView) -> String {
    let content = match (&sound.image, &sound.text) {
        (Some(image), _) => {
            format!(r#"<img width="{}" height="{}" class="align--middle" src="{}" />"#, image.width, image.height, escape(&image.src))
        }
        (None, Some(text)) => escape(text),
        (None, None) => String::new(),
    };
    format!(
        r#"<div class="sound" data-controller="sound" data-action="messages:play-&gt;sound#play" data-sound-url-value="{}"><button class="btn btn--plain" data-action="sound#play">🔊</button>{content}</div>"#,
        escape(&sound.url)
    )
}

/// `Messages::AttachmentPresentation#render`.
pub fn attachment_presentation(ctx: &ViewContext, attachment: &AttachmentView) -> String {
    match &attachment.preview {
        AttachmentPreview::Video { poster_url } => video_preview(attachment, poster_url),
        AttachmentPreview::Image { thumb_url } => lightboxed_image_preview(attachment, thumb_url),
        AttachmentPreview::VoiceMessage { duration } => voice_bubble(ctx, attachment, *duration),
        AttachmentPreview::File => file_link(ctx, attachment),
    }
}

fn voice_bubble(_ctx: &ViewContext, attachment: &AttachmentView, duration: Option<f64>) -> String {
    let dur_secs = duration.unwrap_or(1.0).round().max(1.0).min(60.0) as i64;
    let audio_url = escape(&attachment.blob_path);

    format!(
        concat!(
            r#"<div class="voice-message-container flex align-center gap-half" data-controller="sound" data-sound-url-value="{audio_url}">"#,
            r#"<button type="button" class="voice-bubble btn btn--plain" data-sound-target="bubble" data-action="click->sound#togglePlay" aria-label="播放语音消息">"#,
            r#"<span class="voice-bubble__icon">"#,
            r#"<svg class="voice-soundwave" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">"#,
            r#"<path class="arc arc--1" d="M8 9a4 4 0 0 1 0 6"></path>"#,
            r#"<path class="arc arc--2" d="M12 6a8 8 0 0 1 0 12"></path>"#,
            r#"<path class="arc arc--3" d="M16 3a12 12 0 0 1 0 18"></path>"#,
            r#"</svg>"#,
            r#"</span>"#,
            r#"<span class="voice-waveform flex align-center" aria-hidden="true">"#,
            r#"<span class="voice-bar" style="--bar-h: 6px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 12px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 8px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 16px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 10px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 18px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 14px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 7px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 15px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 20px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 13px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 17px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 9px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 15px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 11px;"></span>"#,
            r#"<span class="voice-bar" style="--bar-h: 7px;"></span>"#,
            r#"</span>"#,
            r#"<span class="voice-bubble__duration">{dur_secs}&quot;</span>"#,
            r#"</button>"#,
            r#"<span class="voice-bubble__unread-dot" data-sound-target="unreadDot"></span>"#,
            r#"<audio preload="none" src="{audio_url}" data-sound-target="audio" data-action="ended->sound#onEnded play->sound#onPlay pause->sound#onPause"></audio>"#,
            r#"</div>"#
        ),
        audio_url = audio_url,
        dur_secs = dur_secs,
    )
}

fn video_preview(attachment: &AttachmentView, poster_url: &str) -> String {
    let video = format!(
        r#"<video src="{}" poster="{}" controls="controls" preload="none" width="100%" height="100%" class="message__attachment"></video>"#,
        escape(&attachment.blob_path),
        escape(poster_url)
    );
    inline_media_dimension_constraints(preview_dimensions(attachment), &video)
}

fn lightboxed_image_preview(attachment: &AttachmentView, thumb_url: &str) -> String {
    let dimensions = preview_dimensions(attachment);
    let size = match dimensions {
        Some((width, height)) => format!(r#" width="{width}" height="{height}""#),
        None => String::new(),
    };
    let image = format!(r#"<img{size} class="message__attachment" loading="lazy" src="{}" />"#, escape(thumb_url));
    let link = format!(
        r#"<a class="flex" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="{}" href="{}">{image}</a>"#,
        escape(&attachment.download_path),
        escape(&attachment.blob_path)
    );
    inline_media_dimension_constraints(dimensions, &link)
}

fn inline_media_dimension_constraints(dimensions: Option<(RubyNumber, RubyNumber)>, content: &str) -> String {
    match dimensions {
        Some((width, height)) => {
            let aspect_ratio = RubyNumber::Float(width.to_f() / height.to_f());
            format!(
                r#"<div class="max-inline-size center flex overflow-clip" style="width: {}px; aspect-ratio: {aspect_ratio};">{content}</div>"#,
                width.half()
            )
        }
        None => format!(r#"<div class="max-inline-size center overflow-clip">{content}</div>"#),
    }
}

/// `preview_dimensions`: the metadata size, scaled down to fit the thumbnail bounds.
fn preview_dimensions(attachment: &AttachmentView) -> Option<(RubyNumber, RubyNumber)> {
    let (width, height) = (attachment.width?, attachment.height?);
    if width.to_f() <= THUMBNAIL_MAX_WIDTH as f64 && height.to_f() <= THUMBNAIL_MAX_HEIGHT as f64 {
        Some((width, height))
    } else {
        let width_factor = THUMBNAIL_MAX_WIDTH as f64 / width.to_f();
        let height_factor = THUMBNAIL_MAX_HEIGHT as f64 / height.to_f();
        let scale = width_factor.min(height_factor);
        Some((RubyNumber::Float(width.to_f() * scale), RubyNumber::Float(height.to_f() * scale)))
    }
}

/// `render_link`: file icon, name, download link and share button, with no whitespace between.
fn file_link(ctx: &ViewContext, attachment: &AttachmentView) -> String {
    let filename = escape(&attachment.filename);
    let download = escape(&attachment.download_path);
    format!(
        concat!(
            r#"<div class="flex-inline align-center gap-half">"#,
            r#"<img class="colorize--black" aria-hidden="true" src="{icon}" width="22" height="22" />"#,
            r#"<span>{filename}</span>"#,
            r#"<a class="btn message__action-btn hide-in-ios-pwa" style="--width: auto;" href="{download}">"#,
            r#"<img aria-hidden="true" src="{download_icon}" width="20" height="20" />"#,
            r#"<span class="for-screen-reader">Download {filename}</span></a>"#,
            r#"<button class="btn message__action-btn" style="--width: auto;" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="{download}">"#,
            r#"<img aria-hidden="true" src="{share_icon}" width="20" height="20" />"#,
            r#"<span class="for-screen-reader">Share {filename}</span></button>"#,
            r#"</div>"#
        ),
        icon = escape(&ctx.asset("common-file-text.svg")),
        download_icon = escape(&ctx.asset("download.svg")),
        share_icon = escape(&ctx.asset("share.svg")),
        filename = filename,
        download = download,
    )
}
