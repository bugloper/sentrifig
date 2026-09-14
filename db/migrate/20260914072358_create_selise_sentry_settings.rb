# frozen_string_literal: true

# Generated with `rails g migration`; edited to add constraints and the
# unique index. Pinned to the 7.1 migration API so hosts on Rails >= 7.1 can
# run it unchanged.
class CreateSeliseSentrySettings < ActiveRecord::Migration[7.1]
  def change
    create_table :selise_sentry_settings do |t|
      t.string  :environment, null: false
      t.boolean :enabled,     null: false, default: true
      t.string  :changed_by

      t.timestamps
    end

    add_index :selise_sentry_settings, :environment, unique: true
  end
end
