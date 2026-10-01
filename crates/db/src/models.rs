//! One module per model under `reference/app/models`.

pub mod account;
pub mod active_storage;
pub mod ban;
pub mod boost;
pub mod first_run;
pub mod membership;
pub mod message;
pub mod push_subscription;
pub mod rich_text_record;
pub mod room;
pub mod search;
pub mod session;
pub mod sound;
pub mod user;
pub mod webhook;
pub mod custom_settings;

pub use account::{Account, AccountSettings};
pub use active_storage::{Attachment, Blob};
pub use ban::Ban;
pub use boost::Boost;
pub use custom_settings::{CustomSettings, validate_username};
pub use first_run::FirstRun;
pub use membership::{Involvement, Membership};
pub use message::{ContentType, Message, NewMessage};
pub use push_subscription::{MAX_PAYLOAD_BODY_BYTES, MAX_PAYLOAD_TITLE_BYTES, PushPayload, PushSubscription};
pub use rich_text_record::RichTextRecord;
pub use room::{Room, RoomType};
pub use search::Search;
pub use session::Session;
pub use sound::Sound;
pub use user::{NewUser, PasswordDigest, Role, Status, User, UserChanges};
pub use webhook::Webhook;
