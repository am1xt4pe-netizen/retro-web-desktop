#!/usr/bin/env ruby
# webdesktop_builder.rb
# A Ruby Sinatra app for building and customizing HTML webdesktops
# and publishing them as PWAs. Inspired by Neocities webdesktops.

require 'sinatra'
require 'sqlite3'
require 'bcrypt'
require 'json'
require 'fileutils'
require 'securerandom'
require 'base64'
require 'rack/utils'
require 'net/http'
require 'uri'
require 'cgi'

# ============================================================================
# CONFIGURATION
# ============================================================================

MAX_UPLOAD_BYTES = 8 * 1024 * 1024 # 8MB cap on file/gallery uploads

# Well-known, stable identifiers from the Internet Archive's game
# collections, offered as one-click "quick add" chips in the editor.
CURATED_GAMES = [
  ['arcade_breakout', 'Breakout', 'arcade', '1976'],
  ['arcade_spaceinvaders', 'Space Invaders', 'arcade', '1978'],
  ['arcade_pacman', 'Pac-Man', 'arcade', '1980'],
  ['arcade_donkeykong', 'Donkey Kong', 'arcade', '1981'],
  ['arcade_frogger', 'Frogger', 'arcade', '1981'],
  ['arcade_galaga', 'Galaga', 'arcade', '1981'],
  ['arcade_defender', 'Defender', 'arcade', '1981'],
  ['arcade_ms_pacman', 'Ms. Pac-Man', 'arcade', '1982'],
  ['arcade_dig_dug', 'Dig Dug', 'arcade', '1982'],
  ['arcade_joust', 'Joust', 'arcade', '1982']
].freeze

configure do
  set :sessions, true

  # SECURITY NOTE: if SESSION_SECRET isn't set, a new random secret is
  # generated on every boot, which invalidates every existing session (users
  # get logged out) whenever the process restarts. Set SESSION_SECRET in
  # production (e.g. `export SESSION_SECRET=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')`).
  set :session_secret, ENV['SESSION_SECRET'] || SecureRandom.hex(64)

  set :public_folder, File.dirname(__FILE__) + '/public'
  set :views, File.dirname(__FILE__) + '/views'
  set :bind, ENV['BIND'] || '0.0.0.0'
  set :port, ENV['PORT'] || 4567

  # Sinatra only serves files from the public folder in production by
  # default. Force it on so bundled tools (/tools/chord_lab.html,
  # /tools/classical_guitar_library.html) work in every environment.
  set :static, true
end

# ============================================================================
# DATABASE SETUP
# ============================================================================

DB_PATH = File.join(File.dirname(__FILE__), 'webdesktop.db')

def db
  @db ||= begin
    conn = SQLite3::Database.new(DB_PATH)
    conn.results_as_hash = true
    conn.execute('PRAGMA foreign_keys = ON')
    conn.busy_timeout = 5000 # wait up to 5s instead of raising "database is locked"
    conn
  end
end

def init_database
  db.execute_batch <<-SQL
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS desktops (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      name TEXT NOT NULL,
      slug TEXT UNIQUE NOT NULL,
      background_color TEXT DEFAULT '#008080',
      background_image TEXT,
      background_repeat TEXT DEFAULT 'no-repeat',
      background_size TEXT DEFAULT 'cover',
      wallpaper_style TEXT DEFAULT 'stretch',
      font_family TEXT DEFAULT 'Tahoma, sans-serif',
      icon_size INTEGER DEFAULT 48,
      grid_size INTEGER DEFAULT 80,
      taskbar_position TEXT DEFAULT 'bottom',
      taskbar_color TEXT DEFAULT '#c0c0c0',
      window_theme TEXT DEFAULT 'classic',
      custom_css TEXT,
      manifest_name TEXT,
      manifest_short_name TEXT,
      manifest_theme_color TEXT DEFAULT '#008080',
      manifest_background_color TEXT DEFAULT '#008080',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (user_id) REFERENCES users(id)
    );

    CREATE TABLE IF NOT EXISTS desktop_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      desktop_id INTEGER NOT NULL,
      item_type TEXT NOT NULL,
      name TEXT NOT NULL,
      icon TEXT DEFAULT 'folder',
      x_position INTEGER DEFAULT 0,
      y_position INTEGER DEFAULT 0,
      content TEXT,
      url TEXT,
      file_path TEXT,
      file_size INTEGER,
      mime_type TEXT,
      metadata TEXT,
      sort_order INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (desktop_id) REFERENCES desktops(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS icon_packs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT,
      svg_data TEXT NOT NULL,
      preview TEXT
    );

    CREATE TABLE IF NOT EXISTS backgrounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      category TEXT,
      url TEXT NOT NULL,
      thumbnail_url TEXT,
      is_tiled INTEGER DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS gallery_images (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      desktop_id INTEGER NOT NULL,
      filename TEXT NOT NULL,
      caption TEXT,
      file_data BLOB,
      file_size INTEGER,
      mime_type TEXT DEFAULT 'image/png',
      sort_order INTEGER DEFAULT 0,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (desktop_id) REFERENCES desktops(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS text_documents (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      desktop_id INTEGER NOT NULL,
      title TEXT NOT NULL,
      content TEXT DEFAULT '',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (desktop_id) REFERENCES desktops(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS retro_games (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      desktop_id INTEGER NOT NULL,
      game_id TEXT NOT NULL,
      game_title TEXT NOT NULL,
      platform TEXT,
      embed_url TEXT NOT NULL,
      thumbnail_url TEXT,
      sort_order INTEGER DEFAULT 0,
      FOREIGN KEY (desktop_id) REFERENCES desktops(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS wallpapers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      desktop_id INTEGER NOT NULL,
      filename TEXT NOT NULL,
      file_data BLOB,
      file_size INTEGER,
      mime_type TEXT DEFAULT 'image/png',
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (desktop_id) REFERENCES desktops(id) ON DELETE CASCADE
    );
  SQL

  seed_default_data

  # CREATE TABLE IF NOT EXISTS does not add columns to pre-existing tables,
  # so migrate databases from older versions of the app here.
  ensure_column('desktops', 'effects', 'TEXT')
  ensure_column('desktop_items', 'parent_id', 'INTEGER')
end

# Adds a column to a table unless it already exists (lightweight migration).
def ensure_column(table, column, definition)
  existing = db.execute("PRAGMA table_info(#{table})").map { |r| r['name'] }
  db.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{definition}") unless existing.include?(column)
end

def seed_default_data
  icons = [
    ['folder', 'system', '<svg viewBox="0 0 24 24" fill="#FFD700"><path d="M20 6h-8l-2-2H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm0 12H4V8h16v10z"/></svg>', 'Folder'],
    ['file', 'system', '<svg viewBox="0 0 24 24" fill="#FFFFFF"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>', 'File'],
    ['image', 'media', '<svg viewBox="0 0 24 24" fill="#4CAF50"><path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/></svg>', 'Image'],
    ['music', 'media', '<svg viewBox="0 0 24 24" fill="#E91E63"><path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"/></svg>', 'Music'],
    ['video', 'media', '<svg viewBox="0 0 24 24" fill="#F44336"><path d="M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z"/></svg>', 'Video'],
    ['game', 'entertainment', '<svg viewBox="0 0 24 24" fill="#9C27B0"><path d="M21 6H3c-1.1 0-2 .9-2 2v8c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-10 7H8v3H6v-3H3v-2h3V8h2v3h3v2zm4.5 2c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4-3c-.83 0-1.5-.67-1.5-1.5S18.67 9 19.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>', 'Game'],
    ['text', 'productivity', '<svg viewBox="0 0 24 24" fill="#2196F3"><path d="M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z"/></svg>', 'Text Document'],
    ['link', 'internet', '<svg viewBox="0 0 24 24" fill="#00BCD4"><path d="M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z"/></svg>', 'Link'],
    ['computer', 'system', '<svg viewBox="0 0 24 24" fill="#607D8B"><path d="M20 18c1.1 0 1.99-.9 1.99-2L22 6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H0v2h24v-2h-4zM4 6h16v10H4V6z"/></svg>', 'Computer'],
    ['trash', 'system', '<svg viewBox="0 0 24 24" fill="#795548"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>', 'Trash'],
    ['gallery', 'media', '<svg viewBox="0 0 24 24" fill="#FF9800"><path d="M22 16V4c0-1.1-.9-2-2-2H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2zm-11-4l2.03 2.71L16 11l4 5H8l3-4zM2 6v14c0 1.1.9 2 2 2h14v-2H4V6H2z"/></svg>', 'Photo Gallery'],
    ['note', 'productivity', '<svg viewBox="0 0 24 24" fill="#FFEB3B"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>', 'Note'],
    ['cd', 'media', '<svg viewBox="0 0 24 24" fill="#CDDC39"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 14.5c-2.49 0-4.5-2.01-4.5-4.5S9.51 7.5 12 7.5s4.5 2.01 4.5 4.5-2.01 4.5-4.5 4.5zm0-5.5c-.55 0-1 .45-1 1s.45 1 1 1 1-.45 1-1-.45-1-1-1z"/></svg>', 'CD/Music'],
    ['email', 'internet', '<svg viewBox="0 0 24 24" fill="#E91E63"><path d="M20 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/></svg>', 'Email'],
    ['heart', 'personal', '<svg viewBox="0 0 24 24" fill="#F44336"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>', 'Favorites'],
    ['star', 'personal', '<svg viewBox="0 0 24 24" fill="#FFC107"><path d="M12 17.27L18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"/></svg>', 'Starred'],
    ['globe', 'internet', '<svg viewBox="0 0 24 24" fill="#03A9F4"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>', 'Web'],
    ['palette', 'creative', '<svg viewBox="0 0 24 24" fill="#9C27B0"><path d="M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9c.83 0 1.5-.67 1.5-1.5 0-.39-.15-.74-.39-1.01-.23-.26-.38-.61-.38-.99 0-.83.67-1.5 1.5-1.5H16c2.76 0 5-2.24 5-5 0-4.42-4.03-8-9-8zm-5.5 9c-.83 0-1.5-.67-1.5-1.5S5.67 9 6.5 9 8 9.67 8 10.5 7.33 12 6.5 12zm3-4C8.67 8 8 7.33 8 6.5S8.67 5 9.5 5s1.5.67 1.5 1.5S10.33 8 9.5 8zm5 0c-.83 0-1.5-.67-1.5-1.5S13.67 5 14.5 5s1.5.67 1.5 1.5S15.33 8 14.5 8zm3 4c-.83 0-1.5-.67-1.5-1.5S16.67 9 17.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>', 'Art'],
    ['camera', 'media', '<svg viewBox="0 0 24 24" fill="#607D8B"><path d="M9.4 10.5l4.77-8.26C13.47 2.09 12.75 2 12 2c-2.4 0-4.6.85-6.32 2.25l3.66 6.35.06-.1zM21.54 9c-.93-2.05-2.58-3.69-4.63-4.63l-.68 3.51c.19.03.37.08.52.14l4.79-2.02zM5.53 9.51l-2.02 4.79c.93 2.05 2.58 3.69 4.63 4.63l2.02-4.79c-.93-2.05-2.58-3.69-4.63-4.63zM15.96 19.54c.19-.03.37-.08.52-.14l4.79 2.02c-.93 2.05-2.58 3.69-4.63 4.63l-2.02-4.79zM8.54 15.96l-4.79 2.02c.93 2.05 2.58 3.69 4.63 4.63l2.02-4.79c-.93-2.05-2.58-3.69-4.63-4.63z"/></svg>', 'Camera'],
    ['clock', 'system', '<svg viewBox="0 0 24 24" fill="#3F51B5"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/></svg>', 'Clock'],
    ['calculator', 'productivity', '<svg viewBox="0 0 24 24" fill="#009688"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 2h2v2h-2V5zm0 4h2v2h-2V9zm0 4h2v2h-2v-2zm-4-8h2v2H8V5zm0 4h2v2H8V9zm0 4h2v2H8v-2zM6 17H4v-2h2v2zm0-4H4v-2h2v2zm0-4H4V7h2v2zm10 8h-2v-2h2v2zm0-4h-2v-2h2v2zm0-4h-2V7h2v2zm4 8h-2v-2h2v2zm0-4h-2v-2h2v2zm0-4h-2V7h2v2z"/></svg>', 'Calculator'],
    ['chat', 'social', '<svg viewBox="0 0 24 24" fill="#8BC34A"><path d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z"/></svg>', 'Chat'],
    ['bookmark', 'personal', '<svg viewBox="0 0 24 24" fill="#FF5722"><path d="M17 3H7c-1.1 0-1.99.9-1.99 2L5 21l7-3 7 3V5c0-1.1-.9-2-2-2z"/></svg>', 'Bookmark'],
    ['rss', 'internet', '<svg viewBox="0 0 24 24" fill="#FF9800"><path d="M6.18 17.82c.8 0 1.45.66 1.45 1.45 0 .8-.65 1.45-1.45 1.45s-1.45-.65-1.45-1.45c0-.79.65-1.45 1.45-1.45zM4 4.44v2.66c4.66 0 8.46 3.8 8.46 8.46h2.66c0-6.14-4.98-11.12-11.12-11.12zm0 5.3v2.66c1.91 0 3.46 1.55 3.46 3.46h2.66c0-3.39-2.75-6.12-6.12-6.12z"/></svg>', 'RSS Feed'],
    ['download', 'system', '<svg viewBox="0 0 24 24" fill="#4CAF50"><path d="M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z"/></svg>', 'Download'],
    ['upload', 'system', '<svg viewBox="0 0 24 24" fill="#2196F3"><path d="M9 16h6v-6h4l-7-7-7 7h4v6zm-4 2h14v2H5v-2z"/></svg>', 'Upload'],
    ['zip', 'system', '<svg viewBox="0 0 24 24" fill="#9E9E9E"><path d="M20 6h-2.18c.11-.31.18-.65.18-1 0-1.66-1.34-3-3-3-1.05 0-1.96.54-2.5 1.35l-.5.67-.5-.68C10.96 2.54 10.05 2 9 2 7.34 2 6 3.34 6 5c0 .35.07.69.18 1H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zM9 4c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm6 0c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1z"/></svg>', 'Archive'],
    ['terminal', 'system', '<svg viewBox="0 0 24 24" fill="#212121"><path d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 14H4V6h16v12zM6 12h2v2H6zm0-3h2v2H6zm0 6h2v2H6zm10-3h2v2h-2zm0-3h2v2h-2zm0 6h2v2h-2z"/></svg>', 'Terminal'],
    ['settings', 'system', '<svg viewBox="0 0 24 24" fill="#757575"><path d="M19.14 12.94c.04-.3.06-.61.06-.94 0-.32-.02-.64-.07-.94l2.03-1.58c.18-.14.23-.41.12-.61l-1.92-3.32c-.12-.22-.37-.29-.59-.22l-2.39.96c-.5-.38-1.03-.7-1.62-.94l-.36-2.54c-.04-.24-.24-.41-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L3.16 8.87c-.12.21-.08.47.12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58c-.18.14-.23.41-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32c.12-.22.07-.47-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/></svg>', 'Settings'],
    ['search', 'system', '<svg viewBox="0 0 24 24" fill="#607D8B"><path d="M15.5 14h-.79l-.28-.27C15.41 12.59 16 11.11 16 9.5 16 5.91 13.09 3 9.5 3S3 5.91 3 9.5 5.91 16 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z"/></svg>', 'Search'],
    ['home', 'personal', '<svg viewBox="0 0 24 24" fill="#795548"><path d="M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z"/></svg>', 'Home'],
    ['user', 'personal', '<svg viewBox="0 0 24 24" fill="#3F51B5"><path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"/></svg>', 'User'],
    ['lock', 'system', '<svg viewBox="0 0 24 24" fill="#F44336"><path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z"/></svg>', 'Lock'],
    ['battery', 'system', '<svg viewBox="0 0 24 24" fill="#8BC34A"><path d="M15.67 4H14V2h-4v2H8.33C7.6 4 7 4.6 7 5.33v15.33C7 21.4 7.6 22 8.33 22h7.33c.74 0 1.34-.6 1.34-1.33V5.33C17 4.6 16.4 4 15.67 4z"/></svg>', 'Battery'],
    ['wifi', 'internet', '<svg viewBox="0 0 24 24" fill="#03A9F4"><path d="M1 9l2 2c4.97-4.97 13.03-4.97 18 0l2-2C16.93 2.93 7.08 2.93 1 9zm8 8l3 3 3-3c-1.65-1.66-4.34-1.66-6 0zm-4-4l2 2c2.76-2.76 7.24-2.76 10 0l2-2C15.14 9.14 8.87 9.14 5 13z"/></svg>', 'WiFi'],
    ['bluetooth', 'system', '<svg viewBox="0 0 24 24" fill="#2196F3"><path d="M17.71 7.71L12 2h-1v7.59L6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 11 14.41V22h1l5.71-5.71-4.3-4.29 4.3-4.29zM13 5.83l1.88 1.88L13 9.59V5.83zm1.88 10.46L13 18.17v-3.76l1.88 1.88z"/></svg>', 'Bluetooth'],
    ['printer', 'system', '<svg viewBox="0 0 24 24" fill="#607D8B"><path d="M19 8H5c-1.66 0-3 1.34-3 3v6h4v2h12v-2h4v-6c0-1.66-1.34-3-3-3zm-3 11H8v-4h8v4zm3-7c-.55 0-1-.45-1-1s.45-1 1-1 1 .45 1 1-.45 1-1 1zm-1-9H6v4h12V3z"/></svg>', 'Printer'],
    ['save', 'system', '<svg viewBox="0 0 24 24" fill="#4CAF50"><path d="M17 3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0 2-.9 2-2V7l-4-4zm-5 16c-1.66 0-3-1.34-3-3s1.34-3 3-3 3 1.34 3 3-1.34 3-3 3zm3-10H5V5h10v4z"/></svg>', 'Save'],
    ['edit', 'productivity', '<svg viewBox="0 0 24 24" fill="#FF9800"><path d="M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04c.39-.39.39-1.02 0-1.41l-2.34-2.34c-.39-.39-1.02-.39-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z"/></svg>', 'Edit'],
    ['delete', 'system', '<svg viewBox="0 0 24 24" fill="#F44336"><path d="M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z"/></svg>', 'Delete'],
    ['play', 'media', '<svg viewBox="0 0 24 24" fill="#4CAF50"><path d="M8 5v14l11-7z"/></svg>', 'Play'],
    ['pause', 'media', '<svg viewBox="0 0 24 24" fill="#FF9800"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>', 'Pause'],
    ['stop', 'media', '<svg viewBox="0 0 24 24" fill="#F44336"><path d="M6 6h12v12H6z"/></svg>', 'Stop'],
    ['volume', 'media', '<svg viewBox="0 0 24 24" fill="#607D8B"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>', 'Volume'],
    ['mute', 'media', '<svg viewBox="0 0 24 24" fill="#9E9E9E"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73 4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>', 'Mute'],
    ['retro_game', 'entertainment', '<svg viewBox="0 0 24 24" fill="#FF5722"><path d="M21 6H3c-1.1 0-2 .9-2 2v8c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-10 7H8v3H6v-3H3v-2h3V8h2v3h3v2zm4.5 2c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4-3c-.83 0-1.5-.67-1.5-1.5S18.67 9 19.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>', 'Retro Game'],
    ['arcade', 'entertainment', '<svg viewBox="0 0 24 24" fill="#E91E63"><path d="M20 5H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm-9 12H4V7h7v10zm9 0h-7V7h7v10z"/></svg>', 'Arcade'],
    ['joystick', 'entertainment', '<svg viewBox="0 0 24 24" fill="#9C27B0"><path d="M21 6H3c-1.1 0-2 .9-2 2v8c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2zm-10 7H8v3H6v-3H3v-2h3V8h2v3h3v2zm4.5 2c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4-3c-.83 0-1.5-.67-1.5-1.5S18.67 9 19.5 9s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>', 'Joystick']
  ]

  existing = db.execute("SELECT name FROM icon_packs").map { |r| r['name'] }
  icons.each do |icon|
    next if existing.include?(icon[0])
    db.execute(
      "INSERT INTO icon_packs (name, category, svg_data, preview) VALUES (?, ?, ?, ?)",
      [icon[0], icon[1], icon[2], icon[3]]
    )
  end

  bg_existing = db.execute("SELECT name FROM backgrounds").map { |r| r['name'] }
  unless bg_existing.include?('Classic Teal')
    [
      ['Classic Teal', 'solid', '#008080', 0],
      ['Windows 95', 'pattern', 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0IiBoZWlnaHQ9IjQiPjxyZWN0IHdpZHRoPSI0IiBoZWlnaHQ9IjQiIGZpbGw9IiMwMDgwODAiLz48L3N2Zz4=', 1],
      ['Midnight Blue', 'solid', '#191970', 0],
      ['Forest Green', 'solid', '#228B22', 0],
      ['Burgundy', 'solid', '#800020', 0],
      ['Charcoal', 'solid', '#36454F', 0]
    ].each do |bg|
      db.execute(
        "INSERT INTO backgrounds (name, category, url, is_tiled) VALUES (?, ?, ?, ?)",
        bg
      )
    end
  end

  # VHS / CRT wallpaper presets (art direction: 1970s VHS style board).
  # url schemes:
  #   solid:<hex>     -> applied as the background color
  #   gradient:<css>  -> applied raw as background-image (may be a comma list)
  #   data:/http...   -> applied as url('<...>')
  noise = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='120'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E"
  amber_grid = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Cpath d='M40 0H0V40' fill='none' stroke='rgba(255,176,0,0.30)' stroke-width='1'/%3E%3C/svg%3E"
  sprocket = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='34' height='22'%3E%3Crect width='34' height='22' fill='%230a0a0a'/%3E%3Ccircle cx='17' cy='11' r='4' fill='%232a2a2a'/%3E%3C/svg%3E"

  vhs_bgs = [
    ['Channel Snow', 'vhs', "gradient:url(\"#{noise}\"), linear-gradient(180deg, #0c0c10 0%, #14141a 100%)", 0],
    ['Test Pattern', 'vhs', "gradient:linear-gradient(180deg, transparent 0% 62%, #000 62% 78%, #0a0a0a 78% 92%, transparent 92% 100%), linear-gradient(90deg, #fff 0% 14.28%, #ff0 14.28% 28.5%, #0ff 28.5% 42.8%, #0f0 42.8% 57%, #f0f 57% 71.2%, #f00 71.2% 85.5%, #00f 85.5% 100%)", 0],
    ['Amber Grid', 'vhs', "gradient:url(\"#{amber_grid}\"), radial-gradient(120% 100% at 50% 50%, #1a0e00 0%, #000 80%)", 1],
    ['CRT Rings', 'vhs', 'gradient:repeating-radial-gradient(circle at 50% 50%, rgba(160,200,255,0.07) 0 2px, transparent 2px 7px), radial-gradient(120% 100% at 50% 40%, #101820 0%, #000 78%)', 0],
    ['Sunset 1979', 'vhs', 'gradient:linear-gradient(180deg, #1a1a4a 0%, #5a2a6a 30%, #c03a6a 55%, #ff7a2a 78%, #ffd24a 100%)', 0],
    ['Film Leader', 'vhs', "gradient:url(\"#{sprocket}\"), radial-gradient(120% 100% at 50% 50%, #caa06a 0%, #6e4a24 60%, #2a1a0a 100%)", 1],
    ['70s Living Room', 'vhs', 'gradient:radial-gradient(circle at 50% 30%, rgba(255,210,120,0.40), transparent 55%), linear-gradient(180deg, #c9b27a 0%, #b7a06a 55%, #9c7a44 100%)', 0],
    ['Deep Space Teal', 'vhs', 'gradient:radial-gradient(120% 100% at 50% 40%, #00404a 0%, #00181f 75%)', 0]
  ]
  vhs_bgs.each do |bg|
    unless bg_existing.include?(bg[0])
      db.execute(
        "INSERT INTO backgrounds (name, category, url, is_tiled) VALUES (?, ?, ?, ?)",
        bg
      )
    end
  end
end

# ============================================================================
# HELPERS
# ============================================================================

helpers do
  def current_user
    return nil unless session[:user_id]
    @current_user ||= db.execute(
      "SELECT * FROM users WHERE id = ?", [session[:user_id]]
    ).first
  end

  def logged_in?
    !!current_user
  end

  def require_login
    redirect '/login' unless logged_in?
  end

  def require_desktop_owner(desktop_id)
    desktop = db.execute("SELECT * FROM desktops WHERE id = ?", [desktop_id]).first
    halt 403, "Not authorized" unless desktop && desktop['user_id'] == current_user['id']
    desktop
  end

  def generate_slug(name)
    base = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')
    base = 'desktop' if base.empty?
    slug = base
    counter = 1
    while db.execute("SELECT id FROM desktops WHERE slug = ?", [slug]).first
      slug = "#{base}-#{counter}"
      counter += 1
    end
    slug
  end

  def next_sort_order(table, desktop_id)
    row = db.execute(
      "SELECT COALESCE(MAX(sort_order), 0) AS max_order FROM #{table} WHERE desktop_id = ?",
      [desktop_id]
    ).first
    row['max_order'].to_i + 1
  end

  # Escapes plain-text fields (names, titles, captions) that get interpolated
  # into HTML/attributes. NOT used on rich-text document content, which is
  # expected to contain formatting HTML from the WYSIWYG editor by design.
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  # Same idea but safe to drop inside a single-quoted JS string literal.
  def js_str(text)
    text.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'").gsub("\n", '\\n')
  end

  # Escapes text for use inside a single-quoted JS string literal that is
  # ITSELF inside an HTML attribute (e.g. onclick="fn('...')"). Order matters:
  # JS-escape first, then HTML-escape the result, so the browser's HTML
  # entity decoding reconstructs a properly JS-escaped string rather than
  # leaking a raw quote that breaks out of the string.
  def js_attr(text)
    h(js_str(text))
  end

  # Safe to embed inside an inline <script> block. Guards against content
  # (item names, captions, doc titles) containing a literal "</script>"
  # sequence, which would otherwise terminate the script tag early and let
  # arbitrary HTML/script run on a page anyone can view.
  # Translates a stored background_image value into CSS for the desktop's
  # body element. Supports the url schemes documented in seed_default_data:
  #   solid:<hex>     -> { 'color' => hex } (applied as background-color)
  #   gradient:<css>  -> { 'image' => css } (applied raw as background-image)
  #   anything else   -> { 'image' => "url('<value>')" }
  # The editor stores whichever string the user picked (or typed), so every
  # rendering surface (published page, preview iframe, HTML export) goes
  # through this one helper and stays consistent.
  def background_image_props(url)
    value = url.to_s.strip
    return {} if value.empty?

    if value.start_with?('solid:')
      hex = value.sub(/\Asolid:/, '')
      return {} unless hex =~ /\A#[0-9a-fA-F]{3,8}\z/
      { 'color' => hex }
    elsif value.start_with?('gradient:')
      { 'image' => value.sub(/\Agradient:/, '') }
    else
      { 'image' => "url('#{value.gsub("'", "%27")}')" }
    end
  end

  # The string stored in desktops.background_image when the user picks a
  # preset from the editor. Legacy solid presets store a bare hex in the url
  # column, so normalize it to the solid:<hex> scheme.
  def bg_preset_value(bg)
    url = bg['url'].to_s
    return "solid:#{url}" if bg['category'] == 'solid' && url =~ /\A#[0-9a-fA-F]{3,8}\z/
    url
  end

  # Inline CSS for a preset swatch in the editor's background picker.
  def bg_preset_style(value)
    props = background_image_props(value)
    css = []
    css << "background-color: #{props['color']}" if props['color']
    css << "background-image: #{props['image']}" if props['image']
    css << 'background-size: cover'
    css.join('; ')
  end

  def safe_json(obj)
    obj.to_json.gsub('</', '<\/')
  end
end

# ============================================================================
# ROUTES - AUTHENTICATION
# ============================================================================

get '/' do
  if logged_in?
    redirect '/dashboard'
  else
    erb :welcome
  end
end

# The themed landing page (feature overview + sign up) lives at /home so
# that / can be the cinematic pre-landing welcome screen, which links here
# via its "Press play to enter" button.
get '/home' do
  if logged_in?
    redirect '/dashboard'
  else
    erb :landing
  end
end

get '/login' do
  erb :login
end

post '/login' do
  user = db.execute("SELECT * FROM users WHERE username = ?", [params[:username]]).first
  if user && BCrypt::Password.new(user['password_hash']) == params[:password]
    session[:user_id] = user['id']
    redirect '/dashboard'
  else
    @error = "Invalid username or password"
    erb :login
  end
end

get '/signup' do
  erb :signup
end

post '/signup' do
  if params[:password] != params[:password_confirm]
    @error = "Passwords do not match"
    return erb :signup
  end

  if params[:password].to_s.length < 6
    @error = "Password must be at least 6 characters"
    return erb :signup
  end

  password_hash = BCrypt::Password.create(params[:password])

  begin
    db.execute(
      "INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)",
      [params[:username], params[:email], password_hash]
    )
    user = db.execute("SELECT * FROM users WHERE username = ?", [params[:username]]).first
    session[:user_id] = user['id']
    redirect '/dashboard'
  rescue SQLite3::ConstraintException
    @error = "Username or email already taken"
    erb :signup
  end
end

get '/logout' do
  session.clear
  redirect '/'
end

# ============================================================================
# ROUTES - DASHBOARD & DESKTOP MANAGEMENT
# ============================================================================

get '/dashboard' do
  require_login
  @desktops = db.execute(
    "SELECT * FROM desktops WHERE user_id = ? ORDER BY updated_at DESC",
    [current_user['id']]
  )
  erb :dashboard
end

get '/desktop/new' do
  require_login
  erb :new_desktop
end

post '/desktop/new' do
  require_login
  name = params[:name].to_s.strip
  halt 400, "Name is required" if name.empty?

  slug = generate_slug(name)

  db.execute(
    "INSERT INTO desktops (user_id, name, slug, manifest_name, manifest_short_name) VALUES (?, ?, ?, ?, ?)",
    [current_user['id'], name, slug, name, name[0..11]]
  )

  desktop_id = db.last_insert_row_id

  default_items = [
    ['folder', 'My Documents', 'folder', 20, 20, nil],
    ['file', 'Readme.txt', 'text', 20, 100, nil],
    ['link', 'My Links', 'link', 20, 180, nil],
    ['gallery', 'My Photos', 'gallery', 20, 260, nil],
    ['game', 'Retro Games', 'retro_game', 20, 340, nil],
    ['link', 'Chord Lab', 'link', 20, 420, '/tools/chord_lab.html'],
    ['link', 'Guitar Library', 'link', 20, 500, '/tools/classical_guitar_library.html']
  ]

  default_items.each_with_index do |item, i|
    db.execute(
      "INSERT INTO desktop_items (desktop_id, item_type, name, icon, x_position, y_position, url, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      [desktop_id, item[0], item[1], item[2], item[3], item[4], item[5], i]
    )
  end

  redirect "/desktop/#{desktop_id}/edit"
end

get '/desktop/:id/edit' do
  require_login
  @desktop = require_desktop_owner(params[:id].to_i)
  @items = db.execute(
    "SELECT * FROM desktop_items WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )
  @icons = db.execute("SELECT * FROM icon_packs ORDER BY category, name")
  @backgrounds = db.execute("SELECT * FROM backgrounds ORDER BY category, name")
  @gallery_images = db.execute(
    "SELECT * FROM gallery_images WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )
  @documents = db.execute(
    "SELECT * FROM text_documents WHERE desktop_id = ? ORDER BY updated_at DESC",
    [@desktop['id']]
  )
  @retro_games = db.execute(
    "SELECT * FROM retro_games WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )
  @wallpapers = db.execute(
    "SELECT * FROM wallpapers WHERE desktop_id = ? ORDER BY created_at DESC",
    [@desktop['id']]
  )
  @curated_games = CURATED_GAMES
  erb :edit_desktop
end

# ============================================================================
# ROUTES - DESKTOP CUSTOMIZATION API
# ============================================================================

post '/api/desktop/:id/update' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  updates = []
  values = []

  # background_image is handled outside the generic loop: an empty value must
  # actually clear the column (e.g. "remove wallpaper"), which the non-empty
  # check below can't express.
  if params.key?('background_image')
    updates << 'background_image = ?'
    values << params['background_image'].to_s
  end

  fields = [
    'background_color', 'background_repeat',
    'background_size', 'wallpaper_style', 'font_family', 'icon_size',
    'grid_size', 'taskbar_position', 'taskbar_color', 'window_theme',
    'custom_css', 'manifest_name', 'manifest_short_name',
    'manifest_theme_color', 'manifest_background_color'
  ]
  fields.each do |field|
    if params[field] && !params[field].to_s.empty?
      updates << "#{field} = ?"
      values << params[field]
    end
  end

  if updates.any?
    values << desktop['id']
    db.execute(
      "UPDATE desktops SET #{updates.join(', ')}, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
      values
    )
  end

  content_type :json
  { success: true }.to_json
end

post '/api/desktop/:id/item' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  name = params[:name].to_s.strip
  halt 400, { success: false, error: 'Name is required' }.to_json if name.empty?

  db.execute(
    "INSERT INTO desktop_items (desktop_id, item_type, name, icon, x_position, y_position, content, url, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      desktop['id'],
      params[:item_type],
      name,
      params[:icon] || 'folder',
      params[:x_position] || 20,
      params[:y_position] || 20,
      params[:content],
      params[:url],
      next_sort_order('desktop_items', desktop['id'])
    ]
  )

  content_type :json
  { success: true, id: db.last_insert_row_id }.to_json
end

post '/api/desktop/:id/item/:item_id/update' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  item = db.execute(
    "SELECT * FROM desktop_items WHERE id = ? AND desktop_id = ?",
    [params[:item_id], desktop['id']]
  ).first
  halt 404 unless item

  updates = []
  values = []
  ['name', 'icon', 'x_position', 'y_position', 'content', 'url'].each do |field|
    if params[field]
      updates << "#{field} = ?"
      values << params[field]
    end
  end

  if updates.any?
    values << params[:item_id]
    db.execute(
      "UPDATE desktop_items SET #{updates.join(', ')} WHERE id = ?",
      values
    )
  end

  content_type :json
  { success: true }.to_json
end

delete '/api/desktop/:id/item/:item_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "DELETE FROM desktop_items WHERE id = ? AND desktop_id = ?",
    [params[:item_id], desktop['id']]
  )

  content_type :json
  { success: true }.to_json
end

# ============================================================================
# ROUTES - FILE UPLOAD
# ============================================================================

post '/api/desktop/:id/upload' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  unless params[:file] && params[:file][:tempfile]
    halt 400, { success: false, error: 'No file uploaded' }.to_json
  end

  file = params[:file]
  filename = File.basename(file[:filename].to_s) # strip any path component
  tempfile = file[:tempfile]
  mime_type = file[:type] || 'application/octet-stream'
  file_size = tempfile.size

  if file_size > MAX_UPLOAD_BYTES
    halt 413, { success: false, error: "File too large (max #{MAX_UPLOAD_BYTES / 1024 / 1024}MB)" }.to_json
  end

  file_data = tempfile.read

  item_type = case mime_type
              when /image\// then 'image'
              when /audio\// then 'music'
              when /video\// then 'video'
              when /text\// then 'text'
              else 'file'
              end

  db.execute(
    "INSERT INTO desktop_items (desktop_id, item_type, name, icon, file_path, file_size, mime_type, content, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    [
      desktop['id'],
      item_type,
      filename,
      item_type == 'image' ? 'image' : 'file',
      filename,
      file_size,
      mime_type,
      Base64.strict_encode64(file_data),
      next_sort_order('desktop_items', desktop['id'])
    ]
  )

  content_type :json
  { success: true, id: db.last_insert_row_id }.to_json
end

# Serves the raw bytes of an uploaded file/image item back out. Public (no
# login) because it needs to work on published desktops for any visitor,
# the same way gallery images already did.
get '/api/desktop/:id/file/:item_id' do
  desktop = db.execute("SELECT * FROM desktops WHERE id = ?", [params[:id].to_i]).first
  halt 404 unless desktop

  item = db.execute(
    "SELECT * FROM desktop_items WHERE id = ? AND desktop_id = ?",
    [params[:item_id], desktop['id']]
  ).first
  halt 404 unless item && item['content']

  content_type item['mime_type'] || 'application/octet-stream'
  attachment item['name'] if item['item_type'] == 'file'
  Base64.strict_decode64(item['content'])
end

# ============================================================================
# ROUTES - PHOTO GALLERY
# ============================================================================

post '/api/desktop/:id/gallery' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  unless params[:image] && params[:image][:tempfile]
    halt 400, { success: false, error: 'No image uploaded' }.to_json
  end

  image = params[:image]
  file_data = image[:tempfile].read

  if file_data.bytesize > MAX_UPLOAD_BYTES
    halt 413, { success: false, error: "Image too large (max #{MAX_UPLOAD_BYTES / 1024 / 1024}MB)" }.to_json
  end

  # Bind as a genuine binary string. (SQLite3::Blob is not part of the
  # public sqlite3 gem API in modern versions -- passing an ASCII-8BIT
  # string is the correct way to insert BLOB data.)
  binary_data = file_data.dup.force_encoding(Encoding::ASCII_8BIT)

  db.execute(
    "INSERT INTO gallery_images (desktop_id, filename, caption, file_data, file_size, mime_type, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      desktop['id'],
      File.basename(image[:filename].to_s),
      params[:caption],
      binary_data,
      binary_data.bytesize,
      image[:type] || 'image/png',
      next_sort_order('gallery_images', desktop['id'])
    ]
  )

  content_type :json
  { success: true, id: db.last_insert_row_id }.to_json
end

delete '/api/desktop/:id/gallery/:image_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "DELETE FROM gallery_images WHERE id = ? AND desktop_id = ?",
    [params[:image_id], desktop['id']]
  )

  content_type :json
  { success: true }.to_json
end

get '/api/desktop/:id/gallery/:image_id' do
  desktop = db.execute("SELECT * FROM desktops WHERE id = ?", [params[:id].to_i]).first
  halt 404 unless desktop

  image = db.execute(
    "SELECT * FROM gallery_images WHERE id = ? AND desktop_id = ?",
    [params[:image_id], desktop['id']]
  ).first
  halt 404 unless image

  content_type image['mime_type'] || 'image/png'
  image['file_data']
end

# ============================================================================
# ROUTES - CUSTOM WALLPAPERS
# ============================================================================
#
# Uploads are stored as BLOBs in the wallpapers table (one row per desktop)
# and the desktop's background_image is pointed at the serving route below,
# so a custom wallpaper behaves exactly like any other background URL on the
# published page and in the editor preview.

post '/api/desktop/:id/wallpaper' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  unless params[:wallpaper] && params[:wallpaper][:tempfile]
    halt 400, { success: false, error: 'No image uploaded' }.to_json
  end

  image = params[:wallpaper]
  mime_type = image[:type].to_s
  halt 400, { success: false, error: 'Unsupported file type' }.to_json unless mime_type =~ /\Aimage\/(png|jpe?g|gif|webp|svg\+xml|avif)\z/

  file_data = image[:tempfile].read
  if file_data.bytesize > MAX_UPLOAD_BYTES
    halt 413, { success: false, error: "Image too large (max #{MAX_UPLOAD_BYTES / 1024 / 1024}MB)" }.to_json
  end

  # Bind as a genuine binary string (same approach as the gallery uploads).
  binary_data = file_data.dup.force_encoding(Encoding::ASCII_8BIT)

  db.execute(
    "INSERT INTO wallpapers (desktop_id, filename, file_data, file_size, mime_type) VALUES (?, ?, ?, ?, ?)",
    [
      desktop['id'],
      File.basename(image[:filename].to_s),
      binary_data,
      binary_data.bytesize,
      mime_type
    ]
  )
  wallpaper_id = db.last_insert_row_id
  wallpaper_url = "/api/desktop/#{desktop['id']}/wallpaper/#{wallpaper_id}"

  # Apply the fresh upload as the desktop background immediately.
  db.execute(
    "UPDATE desktops SET background_image = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
    [wallpaper_url, desktop['id']]
  )

  content_type :json
  { success: true, id: wallpaper_id, url: wallpaper_url }.to_json
end

# Public (no login), like the gallery/file serving routes, because the
# wallpaper must load for any visitor of a published desktop.
get '/api/desktop/:id/wallpaper/:wallpaper_id' do
  desktop = db.execute("SELECT * FROM desktops WHERE id = ?", [params[:id].to_i]).first
  halt 404 unless desktop

  wallpaper = db.execute(
    "SELECT * FROM wallpapers WHERE id = ? AND desktop_id = ?",
    [params[:wallpaper_id], desktop['id']]
  ).first
  halt 404 unless wallpaper

  content_type wallpaper['mime_type'] || 'image/png'
  wallpaper['file_data']
end

delete '/api/desktop/:id/wallpaper/:wallpaper_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  wallpaper = db.execute(
    "SELECT * FROM wallpapers WHERE id = ? AND desktop_id = ?",
    [params[:wallpaper_id], desktop['id']]
  ).first
  halt 404 unless wallpaper

  db.execute(
    "DELETE FROM wallpapers WHERE id = ? AND desktop_id = ?",
    [params[:wallpaper_id], desktop['id']]
  )

  # If this wallpaper was the desktop's background, clear it.
  if desktop['background_image'] == "/api/desktop/#{desktop['id']}/wallpaper/#{wallpaper['id']}"
    db.execute(
      "UPDATE desktops SET background_image = '', updated_at = CURRENT_TIMESTAMP WHERE id = ?",
      [desktop['id']]
    )
  end

  content_type :json
  { success: true }.to_json
end

# ============================================================================
# ROUTES - TEXT EDITOR
# ============================================================================

post '/api/desktop/:id/document' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "INSERT INTO text_documents (desktop_id, title, content) VALUES (?, ?, ?)",
    [desktop['id'], params[:title].to_s.empty? ? 'Untitled' : params[:title], params[:content] || '']
  )

  content_type :json
  { success: true, id: db.last_insert_row_id }.to_json
end

post '/api/desktop/:id/document/:doc_id/update' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "UPDATE text_documents SET title = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ? AND desktop_id = ?",
    [params[:title], params[:content], params[:doc_id], desktop['id']]
  )

  content_type :json
  { success: true }.to_json
end

get '/api/desktop/:id/document/:doc_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  doc = db.execute(
    "SELECT * FROM text_documents WHERE id = ? AND desktop_id = ?",
    [params[:doc_id], desktop['id']]
  ).first
  halt 404 unless doc

  content_type :json
  doc.to_json
end

delete '/api/desktop/:id/document/:doc_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "DELETE FROM text_documents WHERE id = ? AND desktop_id = ?",
    [params[:doc_id], desktop['id']]
  )

  content_type :json
  { success: true }.to_json
end

# ============================================================================
# ROUTES - RETRO GAMES (Internet Archive)
# ============================================================================

post '/api/desktop/:id/game' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "INSERT INTO retro_games (desktop_id, game_id, game_title, platform, embed_url, thumbnail_url, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
      desktop['id'],
      params[:game_id],
      params[:game_title],
      params[:platform],
      params[:embed_url],
      params[:thumbnail_url],
      next_sort_order('retro_games', desktop['id'])
    ]
  )

  content_type :json
  { success: true, id: db.last_insert_row_id }.to_json
end

delete '/api/desktop/:id/game/:game_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  db.execute(
    "DELETE FROM retro_games WHERE id = ? AND desktop_id = ?",
    [params[:game_id], desktop['id']]
  )

  content_type :json
  { success: true }.to_json
end

# ============================================================================
# ROUTES - PUBLISH / PREVIEW
# ============================================================================

get '/desktop/:slug' do
  @desktop = db.execute("SELECT * FROM desktops WHERE slug = ?", [params[:slug]]).first
  halt 404 unless @desktop

  @items = db.execute(
    "SELECT * FROM desktop_items WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )
  @icons = db.execute("SELECT * FROM icon_packs ORDER BY category, name")
  @gallery_images = db.execute(
    "SELECT * FROM gallery_images WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )
  @documents = db.execute(
    "SELECT * FROM text_documents WHERE desktop_id = ? ORDER BY updated_at DESC",
    [@desktop['id']]
  )
  @retro_games = db.execute(
    "SELECT * FROM retro_games WHERE desktop_id = ? ORDER BY sort_order",
    [@desktop['id']]
  )

  erb :published_desktop, layout: false
end

get '/desktop/:slug/manifest.json' do
  @desktop = db.execute("SELECT * FROM desktops WHERE slug = ?", [params[:slug]]).first
  halt 404 unless @desktop

  content_type 'application/json'
  erb :manifest, layout: false
end

# BUGFIX: this route never loaded @desktop before rendering service_worker.erb,
# which references @desktop['slug'] -- it would 500 on every request.
get '/desktop/:slug/service-worker.js' do
  @desktop = db.execute("SELECT * FROM desktops WHERE slug = ?", [params[:slug]]).first
  halt 404 unless @desktop

  content_type 'application/javascript'
  erb :service_worker, layout: false
end

# ============================================================================
# ROUTES - EXPORT
# ============================================================================

get '/desktop/:id/export' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  @desktop = desktop

  # A custom wallpaper is served from a /api/.../wallpaper/... route, which
  # is useless inside a standalone file -- swap it for an embedded data URI
  # so the export keeps its background fully offline.
  @export_bg_image = desktop['background_image']
  if @export_bg_image.to_s =~ %r{\A/api/desktop/(\d+)/wallpaper/(\d+)\z}
    wp = db.execute(
      "SELECT * FROM wallpapers WHERE id = ? AND desktop_id = ?",
      [Regexp.last_match(2).to_i, desktop['id']]
    ).first
    if wp
      @export_bg_image = "data:#{wp['mime_type'] || 'image/png'};base64,#{Base64.strict_encode64(wp['file_data'].to_s)}"
    end
  end
  @items = db.execute(
    "SELECT * FROM desktop_items WHERE desktop_id = ? ORDER BY sort_order",
    [desktop['id']]
  )
  @icons = db.execute("SELECT * FROM icon_packs ORDER BY category, name")

  # Embed gallery images as base64 data URIs so the exported HTML is
  # genuinely standalone and doesn't depend on the original server still
  # running to display photos.
  @gallery_images = db.execute(
    "SELECT * FROM gallery_images WHERE desktop_id = ? ORDER BY sort_order",
    [desktop['id']]
  ).map do |img|
    img.merge('data_uri' => "data:#{img['mime_type'] || 'image/png'};base64,#{Base64.strict_encode64(img['file_data'].to_s)}")
  end

  # desktop_items.content is already base64 for uploaded file/image items,
  # so it can become a data URI directly without touching the DB again.
  @items = @items.map do |item|
    if item['content'] && %w[image file].include?(item['item_type'])
      item.merge('data_uri' => "data:#{item['mime_type'] || 'application/octet-stream'};base64,#{item['content']}")
    else
      item
    end
  end

  @documents = db.execute(
    "SELECT * FROM text_documents WHERE desktop_id = ? ORDER BY updated_at DESC",
    [desktop['id']]
  )
  @retro_games = db.execute(
    "SELECT * FROM retro_games WHERE desktop_id = ? ORDER BY sort_order",
    [desktop['id']]
  )

  html = erb :export_html, layout: false

  content_type 'text/html'
  attachment "#{desktop['slug']}.html"
  html
end

get '/desktop/:id/export-pdf/:doc_id' do
  require_login
  desktop = require_desktop_owner(params[:id].to_i)

  doc = db.execute(
    "SELECT * FROM text_documents WHERE id = ? AND desktop_id = ?",
    [params[:doc_id], desktop['id']]
  ).first
  halt 404 unless doc

  erb :export_pdf, layout: false, locals: { doc: doc }
end

# ============================================================================
# ERROR HANDLERS
# ============================================================================

not_found do
  erb :not_found
end

error 500 do
  'Internal Server Error'
end

# ============================================================================
# MAIN
# ============================================================================

if __FILE__ == $0
  init_database
  puts "WebDesktop Builder starting on http://localhost:#{settings.port}"
  puts "Database: #{DB_PATH}"
  Sinatra::Application.run!
end
