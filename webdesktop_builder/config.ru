require './webdesktop_builder'

# Ensure tables/seed data exist whenever the app is booted via rackup/puma,
# not just when running `ruby webdesktop_builder.rb` directly.
init_database

run Sinatra::Application
