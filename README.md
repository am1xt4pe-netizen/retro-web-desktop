# WebDesktop Builder

A Ruby Sinatra application for building and customizing retro HTML "webdesktops"
(à la Neocities desktop pages) and publishing them as installable Progressive Web Apps.

## Features

- 🔐 User authentication (sign up / sign in)
- 🖥️ Customizable web desktop with drag-and-drop icons
- 🎨 Background customization (colors, images, styles)
- 📁 File and folder management (uploaded files are downloadable/viewable)
- 🖼️ Photo gallery with image upload
- 📝 Rich text editor with save and PDF export (via browser print)
- 🎮 Internet Archive retro PC game embedding
- 📱 PWA support (manifest.json + service worker)
- 📤 Export to standalone, offline-capable HTML (images embedded as data URIs)

## Installation

**Easiest way on macOS — double-click to start:**

Double-click **`Start WebDesktop Builder.command`** in Finder. It installs
everything on first run, starts the server, and opens your browser to it
automatically. Run it again any time (tomorrow, next week, etc.) and it'll
either start the server fresh or, if it's already running, just reopen the
browser tab.

> First double-click may get blocked by macOS Gatekeeper since it's an
> unsigned script. If so: right-click (Control-click) the file → **Open** →
> confirm **Open** in the dialog. You only need to do that once.

**Quickest way from a terminal — one command:**

```bash
./start.sh
```

This checks for Ruby/Bundler, runs `bundle install` if needed, generates a
persistent session secret (saved to `.session_secret`, gitignored, reused on
every future run so restarts don't log everyone out), and boots the server.
Then visit `http://localhost:4567`.

**Manual way**, if you'd rather run the steps yourself:

1. Install Ruby 3.x and Bundler.
2. Install dependencies:
   ```bash
   bundle install
   ```
3. Set a stable session secret (otherwise a new one is generated on every
   restart and everyone gets logged out):
   ```bash
   export SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
   ```
4. Run the application:
   ```bash
   ruby webdesktop_builder.rb
   ```
   Or via Rack (recommended for anything beyond local testing):
   ```bash
   bundle exec rackup
   ```
5. Visit `http://localhost:4567`

Optional: `PORT` and `BIND` env vars override the default `4567` / `0.0.0.0`
(`start.sh` respects `PORT` too).

## Usage

1. Sign up for an account.
2. Create your first desktop.
3. Customize appearance: background, icon size, taskbar, window theme.
4. Add items: folders, files, links, photo gallery, text documents, retro games.
5. Preview your desktop, then publish it (it's live at `/desktop/:slug` as soon
   as it's created) or export it as standalone HTML.

## Internet Archive Games

1. Visit https://archive.org/details/internetarcade or
   https://archive.org/details/softwarelibrary_msdos
2. Find a game and note its identifier (e.g. `msdos_Prince_of_Persia_1990`)
3. In the Games tab, enter the title and ID.

## Database

Uses SQLite3. `webdesktop.db` is created automatically on first run (both via
`ruby webdesktop_builder.rb` directly and via `rackup`/Puma).

## API Endpoints

- `POST /api/desktop/:id/update` — update desktop settings
- `POST /api/desktop/:id/item` — add desktop item
- `POST /api/desktop/:id/item/:item_id/update` — update item
- `DELETE /api/desktop/:id/item/:item_id` — delete item
- `POST /api/desktop/:id/upload` — upload a file item (8MB cap)
- `GET /api/desktop/:id/file/:item_id` — serve an uploaded file/image item back out
- `POST /api/desktop/:id/gallery` — upload a gallery image (8MB cap)
- `GET /api/desktop/:id/gallery/:image_id` — serve a gallery image
- `POST /api/desktop/:id/document` — create a text document
- `POST /api/desktop/:id/game` — add a retro game

## File Structure

```
webdesktop_builder.rb   # Main application
config.ru                # Rack entry point
Gemfile
views/
  layout.erb
  landing.erb
  login.erb
  signup.erb
  dashboard.erb
  new_desktop.erb
  edit_desktop.erb
  published_desktop.erb
  manifest.erb
  service_worker.erb
  export_html.erb
  export_pdf.erb
  not_found.erb
public/
  css/style.css
  js/app.js
```

## Known limitations / things to harden further before production

- **Rich-text document content is rendered as raw HTML by design** (that's
  how the WYSIWYG editor's output gets displayed). This is fine for a
  single-owner hobby deploy, but if you're letting untrusted users create
  desktops on a shared instance, add a real HTML sanitizer (e.g. the
  `sanitize` gem) on save, since a malicious "document" could otherwise run
  script in a visitor's browser. Everywhere *else* in the app (item names,
  captions, titles) is already HTML-escaped and JSON embedded in `<script>`
  blocks is escaped against `</script>` breakout.
- **No CSRF tokens** on the JSON API endpoints. Sinatra's default
  `Rack::Protection` covers some common attack classes, but for a
  multi-user production deploy you'd want explicit CSRF tokens on the
  state-changing `fetch()` calls in `edit_desktop.erb`.
- **SQLite** is fine for a small/personal deployment but will hit
  `database is locked` more often under real concurrent write load; a
  `busy_timeout` is set to reduce this, but a real Postgres/MySQL backend
  would be the next step for anything with meaningful traffic.
- **Uploads are capped at 8MB** and stored as base64 in SQLite (simple, but
  not the most storage-efficient approach for many/large files — moving to
  disk or object storage would scale better).

## License

MIT
