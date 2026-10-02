# CHANGELOG

This document records new features and version updates for the Campfire project.

---

## [2026-10-02] Pinned Messages Support

### Description
This release adds pinned message support to public and closed chat rooms.

### Key Capabilities
- **Pin Action in Message Menu**:
  Administrators can click the options menu (`...`) on any message to pin it to the room.
  The pin action is hidden for regular members.
  Each room supports one pinned message at a time. Pinning a new message replaces the active pin.

- **Floating Pin Banner**:
  A floating card appears directly below the top navigation bar (`#nav`).
  The card has a rounded-rectangle shape in both collapsed and expanded states.
  In collapsed mode, the card shows a compact bar (height 32px) with a white badge icon.
  Text messages show a truncated text preview.
  Media and file attachments show a single emoji:
  - Image: 📷
  - Video: 🎬
  - Audio or Voice: 🎵
  - File or Document: 📁

- **Card Expand Details**:
  Users can click the card to expand or collapse it.
  When expanded, the compact preview summary hides to keep the focus on the full content.
  The expanded view shows the full message presentation (rich text, image, playable voice bubble, video, or file).
  The bottom metadata bar shows `{user}` with left margin spacing.
  Administrators can click the unpin icon button inside the expanded card to remove the pin.

- **Real-Time Synchronization**:
  Pin and unpin actions broadcast through Action Cable Turbo Streams.
  All connected users see the pinned card update or disappear immediately.
  When a pinned message is edited or deleted, the pin card updates or removes automatically.

---

## [2026-10-01] Voice Message Support

### Description
This release adds a voice message feature to the chat room.

### Key Capabilities
- **Voice Button**:
  A voice button replaces the static chat icon on the left of the input field.
  The button shows a circle with horizontal sound waves.

- **Audio Record Panel**:
  When you click the voice button, a panel opens and covers the input field.
  The panel supports hands-free audio recording.
  A timer stops the record operation automatically after 60 seconds.
  The panel shows live sound waves during the audio record.
  You can pause the audio, listen to a preview, cancel with the trash icon, or send the message.

- **Voice Message Bubble**:
  Voice messages use a pill-style bubble for light and dark themes.
  Each bubble contains a play button, 16 soundwave bars, and a duration label.
  Unread messages show a red dot indicator.
  The red dot disappears after playback.
  When an audio message finishes, the system plays the next unread voice message automatically.

- **Download Permissions**:
  Voice messages do not include a download button.
  Standard audio files (such as MP3 and WAV) and video files keep full download buttons.

---

## [2026-10-01] User Management, Invite Controls, and Username System

### Description
This release adds a user management panel, a global invite link switch, and support for standard alphanumeric usernames without email addresses.
The implementation uses an additive architecture to keep upstream compatibility.
All new features use dedicated tables and files to prevent merge conflicts with upstream updates.

### User Management Panel
- **Page Layout**:
  The title is "Users" and stays in the center.
  Top spacing prevents navigation buttons on mobile screens from covering the title.

- **Member Management Actions**:
  - **Create Members**: Administrators can create new accounts with a name, username, password, and role.
  - **Change Roles**: Administrators can promote a member to administrator or demote an administrator to member.
  - **Reset Passwords**: Administrators can set a new password for a member.
    The system terminates all active sessions for that member immediately.
  - **Lock and Unlock Accounts**: Administrators can lock an account to disconnect active sessions and WebSocket connections.
    Locked users cannot sign in.
    The system keeps all chat messages from locked users.
    Administrators can unlock accounts at any time.
  - **Delete Accounts**: Administrators can delete unused accounts from the database.

- **User Interface Design**:
  - The member list displays accounts directly without redundant titles.
  - Only the "Locked" status badge shows on locked accounts.
  - A crown icon identifies administrators.
  - Action buttons (crown, key, lock, and trash) use round icon buttons.

### Invite Link Global Switch
- **Switch Control**:
  The user management panel provides a switch for the invite link.
  The switch is ON by default.

- **Access Restriction**:
  - When the switch is OFF, the account settings page (`/account/edit`) hides the invite card and QR code.
  - The chat view hides the new-member invite banner.
  - When a user opens an invite link (`/join/:join_code`), the server returns HTTP 404.
  - When an administrator turns the switch ON, the system restores the invite link immediately.

### Username System Without Email Restrictions
- **Alphanumeric Usernames**:
  Sign-up and sign-in accept alphanumeric strings between 1 and 64 characters.
  Allowed characters are letters, numbers, hyphens (`-`), and underscores (`_`).
  Email addresses remain fully supported.

- **Case Insensitivity**:
  The system trims and normalizes usernames to lowercase during sign-up and sign-in.
  Users can type uppercase or lowercase characters to sign in.

### Architectural Details
- **Custom Settings Table (`custom_settings`)**:
  The database schema adds a `custom_settings` table in `crates/db/src/schema.rs` under `ADDITIONS`.
  The original `accounts` and `users` tables remain unchanged.

- **New Dedicated Files**:
  - Admin controller: `crates/campfire/src/controllers/admin.rs`
  - Admin views and templates: `crates/views/src/admin.rs` and `crates/views/templates/admin/users/index.html`
  - Settings models: `crates/db/src/models/custom_settings.rs`

---

## [2026-10-01] Image Preview Gestures and Mouse Controls

### Description
This release adds touch gestures and mouse controls to the image preview lightbox.
Users can zoom in to see details and pan images freely.

### Desktop Controls (Mouse)
- **Wheel Zoom**:
  1. Move the mouse cursor over the image.
  2. Rotate the mouse wheel forward to zoom in up to 5x magnification.
     The zoom focuses on the current cursor position.
  3. Rotate the mouse wheel backward to zoom out down to 1x scale.

- **Pan**:
  - When the image scale is larger than 1x, hold the left mouse button and drag to pan.
  - The cursor changes to grab and grabbing styles.

- **Double-Click Zoom**:
  - Double-click the image to switch between 1x scale and 2.5x magnification.

- **Close Preview**:
  - To close the preview, click the dark background, click the close button, or press `ESC`.
  - The window resets the zoom and pan values on close.

### Mobile Controls (Touch Screen)
- **Pinch to Zoom**:
  - Pinch or spread two fingers on the image to adjust magnification between 1x and 5x.

- **One-Finger Pan**:
  - When the image is larger than 1x, slide one finger to pan the image.

- **Double-Tap Zoom**:
  - Double-tap the image to switch between 1x scale and 2.5x magnification.

- **Close Preview**:
  - Tap the dark background outside the image to close the preview window.

### Technical Implementation Details
- **Asset Override**:
  The file `crates/assets/overrides/controllers/lightbox_controller.js` overrides the upstream Stimulus controller.
  This change does not modify the `reference/` git submodule.

- **Hardware Acceleration**:
  The controller uses CSS3 `transform: translate3d(...) scale(...)` for rendering.
  Transitions are disabled during drag and zoom actions to keep 60 frames per second response.
  Transitions are enabled for double-click and reset animations.

- **Viewport Boundary Constraints**:
  Boundary algorithms prevent the user from moving images outside the visible area.
