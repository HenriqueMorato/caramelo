# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_23_112902) do
  create_table "institutions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false, collation: "NOCASE"
    t.text "notes"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "name"], name: "index_institutions_on_user_id_and_name", unique: true
  end

  create_table "instruments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "BRL", null: false
    t.string "exchange", default: "BVMF", null: false, collation: "NOCASE"
    t.string "name", null: false
    t.string "ticker", null: false, collation: "NOCASE"
    t.datetime "updated_at", null: false
    t.index ["exchange", "ticker"], name: "index_instruments_on_exchange_and_ticker", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "trades", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, null: false
    t.integer "fees_cents", default: 0, null: false
    t.integer "institution_id"
    t.integer "instrument_id", null: false
    t.text "notes"
    t.decimal "quantity", precision: 20, scale: 8, null: false
    t.string "side", null: false
    t.date "traded_on", null: false
    t.integer "unit_price_cents", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["institution_id"], name: "index_trades_on_institution_id"
    t.index ["instrument_id"], name: "index_trades_on_instrument_id"
    t.index ["user_id", "instrument_id", "traded_on"], name: "index_trades_on_user_id_and_instrument_id_and_traded_on"
    t.index ["user_id", "traded_on"], name: "index_trades_on_user_id_and_traded_on"
    t.check_constraint "fees_cents >= 0", name: "trades_fees_nonnegative"
    t.check_constraint "quantity > 0", name: "trades_quantity_positive"
    t.check_constraint "side IN ('buy', 'sell')", name: "trades_side_check"
    t.check_constraint "unit_price_cents > 0", name: "trades_unit_price_positive"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "institutions", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "trades", "institutions"
  add_foreign_key "trades", "instruments"
  add_foreign_key "trades", "users"
end
