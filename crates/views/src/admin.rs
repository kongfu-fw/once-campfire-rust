//! View models for administrator pages (fork extension).

use askama::Template;
use crate::ViewContext;
use crate::helpers::{self as h, filters};
use crate::layouts::Page;

#[derive(Clone, Debug)]
pub struct AdminUserItem {
    pub id: i64,
    pub name: String,
    pub email_address: String,
    pub role: String,
    pub is_admin: bool,
    pub is_banned: bool,
    pub is_current_user: bool,
    pub avatar_url: String,
}

#[derive(Template)]
#[template(path = "admin/users/index.html", blocks = ["head", "content"])]
pub struct UsersIndex<'a> {
    pub ctx: &'a ViewContext<'a>,
    pub join_code: String,
    pub allow_invites: bool,
    pub users: Vec<AdminUserItem>,
}

impl Page for UsersIndex<'_> {
    fn page_title(&self) -> Option<String> {
        Some("User Management".into())
    }
}
