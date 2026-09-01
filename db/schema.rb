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

ActiveRecord::Schema[8.1].define(version: 2026_09_01_110001) do
  create_table "daily_closing_prices", force: :cascade do |t|
    t.decimal "close_price", precision: 28, scale: 8, null: false
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, null: false
    t.integer "instrument_id", null: false
    t.datetime "observed_at", null: false
    t.string "provider", limit: 64, null: false
    t.date "trading_date", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id", "trading_date", "provider"], name: "index_daily_closing_prices_on_instrument_date_provider", unique: true
    t.index ["instrument_id"], name: "index_daily_closing_prices_on_instrument_id"
    t.check_constraint "close_price > 0", name: "daily_closing_prices_close_positive"
  end

  create_table "historical_data_backfills", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.date "from_date", null: false
    t.integer "generation", default: 1, null: false
    t.integer "instrument_id", null: false
    t.datetime "updated_at", null: false
    t.index ["instrument_id", "currency"], name: "index_historical_data_backfills_on_instrument_id_and_currency", unique: true
    t.index ["instrument_id"], name: "index_historical_data_backfills_on_instrument_id"
  end

  create_table "historical_exchange_rates", force: :cascade do |t|
    t.string "base_currency", limit: 3, null: false
    t.datetime "created_at", null: false
    t.datetime "fetched_at", null: false
    t.datetime "observed_at", null: false
    t.string "provider", limit: 64, null: false
    t.string "quote_currency", limit: 3, null: false
    t.decimal "rate", precision: 28, scale: 12, null: false
    t.date "rate_date", null: false
    t.datetime "updated_at", null: false
    t.index ["base_currency", "quote_currency", "rate_date", "provider"], name: "index_historical_exchange_rates_on_pair_date_provider", unique: true
    t.check_constraint "base_currency <> quote_currency", name: "historical_exchange_rates_currencies_distinct"
    t.check_constraint "rate > 0", name: "historical_exchange_rates_rate_positive"
  end

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
    t.string "asset_type", default: "other", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "BRL", null: false
    t.string "exchange", default: "BVMF", null: false, collation: "NOCASE"
    t.string "name", null: false
    t.string "ticker", null: false, collation: "NOCASE"
    t.datetime "updated_at", null: false
    t.index ["asset_type"], name: "index_instruments_on_asset_type"
    t.index ["exchange", "ticker"], name: "index_instruments_on_exchange_and_ticker", unique: true
    t.check_constraint "asset_type IN ('stock', 'etf', 'fund', 'bond', 'crypto', 'other')", name: "instruments_asset_type_check"
  end

  create_table "market_benchmark_observations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.integer "market_benchmark_id", null: false
    t.datetime "observed_at", null: false
    t.date "observed_on", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.decimal "value", precision: 28, scale: 12, null: false
    t.index ["market_benchmark_id", "observed_on", "provider"], name: "index_market_benchmark_observations_uniqueness", unique: true
    t.index ["market_benchmark_id"], name: "index_market_benchmark_observations_on_market_benchmark_id"
  end

  create_table "market_benchmarks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.string "identifier", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_market_benchmarks_on_identifier", unique: true
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
    t.decimal "unit_price", precision: 28, scale: 8, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["institution_id"], name: "index_trades_on_institution_id"
    t.index ["instrument_id"], name: "index_trades_on_instrument_id"
    t.index ["user_id", "instrument_id", "traded_on"], name: "index_trades_on_user_id_and_instrument_id_and_traded_on"
    t.index ["user_id", "traded_on"], name: "index_trades_on_user_id_and_traded_on"
    t.check_constraint "fees_cents >= 0", name: "trades_fees_nonnegative"
    t.check_constraint "quantity > 0", name: "trades_quantity_positive"
    t.check_constraint "side IN ('buy', 'sell')", name: "trades_side_check"
    t.check_constraint "unit_price > 0", name: "trades_unit_price_positive"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "daily_closing_prices", "instruments"
  add_foreign_key "historical_data_backfills", "instruments"
  add_foreign_key "institutions", "users"
  add_foreign_key "market_benchmark_observations", "market_benchmarks"
  add_foreign_key "sessions", "users"
  add_foreign_key "trades", "institutions"
  add_foreign_key "trades", "instruments"
  add_foreign_key "trades", "users"
end
