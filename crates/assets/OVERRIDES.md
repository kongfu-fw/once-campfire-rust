# Frontend overrides

Files in `overrides/` shadow the reference app's assets of the same logical path (the path under
`app/javascript`, `app/assets/*` or a vendored gem's asset directory), so the Rust app can change its
frontend without editing the `reference/` submodule. `build.rs` puts that directory first on the load
path.

| File | Differs from the reference by |
|---|---|
| `models/file_uploader.js` | No `X-CSRF-Token` header: pages carry no CSRF token (forgery protection is by `Sec-Fetch-Site`) |
| `controllers/copy_to_clipboard_controller.js` | A `url` value: a path, copied as an absolute URL against the page, so the cached message markup that carries it doesn't depend on the request's host |
| `controllers/lightbox_controller.js` | Image zoom & pan: supports mouse wheel zoom and drag on desktop, two-finger pinch-to-zoom and pan on touch devices |
| `lib/autocomplete/base_autocomplete_handler.js` | Asks for JSON (`Accept: application/json`). The reference passes `{ as: "json" }`, a `@rails/request.js` option, to plain `fetch`, gets HTML and never shows the new-ping suggestions |
| `install-edge.svg` | New: a copy of `external/install-edge.svg` where `pwa/_install_instructions` looks for it. Rails can't find it, so Edge gets a 500 on profile and room pages |
| `controllers/composer_controller.js` | Adds WhatsApp-style voice recording overlay panel, MediaRecorder, live waveform visualization, 60s timer, pause & preview, voice audio upload, and sidebar toggle collapse for pinned message |
| `controllers/sound_controller.js` | Supports voice message playback, soundwave animation, unplayed red dot tracking in localStorage, and sequential auto-next playback |
| `composer.css` | Styles for the composer voice button and the WhatsApp-style voice recording overlay panel |
| `messages.css` | Styles for voice message bubbles, voice-soundwave icon, 16-bar voiceprint waveform, unplayed red dots, message pin button, and floating pinned message card with dark mode auto-switching and mobile sidebar-toggle hiding |
| `wechat-voice.svg` | New: Voice toggle icon for composer input bar (horizontal radiating waves in circle) |
| `unlock.svg` | New: Unlock icon matching Campfire lock.svg solid fill style with shackle unfolding outward to the right and centered keyhole |
| `pin.svg` | New: Pushpin icon for message actions menu |
| `pin-off.svg` | New: Unpin icon for pinned message removal |


