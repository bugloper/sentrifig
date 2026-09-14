# frozen_string_literal: true

# Generated with `rails g migration`; edited to add constraints and the
# unique index. Pinned to the 7.1 migration API so hosts on Rails >= 7.1 can
# run it unchanged.
class CreateSentrifigSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :sentrifig_settings do |t|
      t.string  :environment, null: false
      # "backend" gates this app's Sentry SDK; "frontend" is served to browser
      # clients and gates theirs. The default is not a backfill (this migration
      # creates the table) -- it is so any insert that predates the column
      # lands on the backend switch rather than violating null: false.
      t.string  :scope,       null: false, default: "backend"
      t.boolean :enabled,     null: false, default: true
      t.string  :changed_by

      t.timestamps
    end

    add_index :sentrifig_settings, %i[environment scope], unique: true
  end
end
