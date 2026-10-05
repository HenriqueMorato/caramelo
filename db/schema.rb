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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_130000) do
  create_table "corporate_action_import_scans", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "failure_message"
    t.integer "instrument_id", null: false
    t.date "requested_from"
    t.date "requested_to"
    t.string "run_id", limit: 64
    t.date "scanned_through"
    t.string "source", limit: 64, default: "yahoo_finance", null: false
    t.datetime "started_at"
    t.string "status", limit: 16, default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["instrument_id"], name: "index_corporate_action_import_scans_on_instrument_id"
    t.index ["user_id", "instrument_id", "source"], name: "index_corporate_action_import_scans_uniqueness", unique: true
    t.index ["user_id", "status"], name: "index_corporate_action_import_scans_on_owner_status"
    t.index ["user_id"], name: "index_corporate_action_import_scans_on_user_id"
    t.check_constraint "(requested_from IS NULL AND requested_to IS NULL) OR (requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)", name: "corporate_action_import_scans_requested_range"
    t.check_constraint "source IN ('yahoo_finance')", name: "corporate_action_import_scans_source"
    t.check_constraint "status IN ('pending', 'queued', 'running', 'succeeded', 'failed')", name: "corporate_action_import_scans_status"
  end

  create_table "corporate_action_imports", force: :cascade do |t|
    t.text "amount_per_share"
    t.integer "corporate_action_id"
    t.datetime "created_at", null: false
    t.string "currency", limit: 3
    t.date "event_on"
    t.date "ex_date"
    t.text "failure_message"
    t.integer "gross_amount_cents"
    t.integer "institution_id"
    t.integer "instrument_id"
    t.string "kind", limit: 32
    t.integer "net_amount_cents"
    t.text "normalized_data", default: "{}", null: false
    t.date "paid_on"
    t.string "provider_exchange", limit: 16
    t.string "provider_symbol", limit: 64
    t.integer "ratio_denominator"
    t.integer "ratio_numerator"
    t.text "raw_payload", default: "{}", null: false
    t.datetime "reviewed_at"
    t.string "slug", null: false
    t.string "source", limit: 64, null: false
    t.string "source_reference", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.text "warnings", default: "[]", null: false
    t.integer "withholding_tax_cents"
    t.index ["corporate_action_id"], name: "index_corporate_action_imports_on_corporate_action_id"
    t.index ["institution_id"], name: "index_corporate_action_imports_on_institution_id"
    t.index ["instrument_id"], name: "index_corporate_action_imports_on_instrument_id"
    t.index ["slug"], name: "index_corporate_action_imports_on_slug", unique: true
    t.index ["user_id", "instrument_id", "status"], name: "index_corporate_action_imports_on_owner_instrument_status"
    t.index ["user_id", "source", "source_reference"], name: "index_corporate_action_imports_on_owner_source_reference", unique: true
    t.index ["user_id", "status", "event_on"], name: "index_corporate_action_imports_on_owner_status_event"
    t.index ["user_id"], name: "index_corporate_action_imports_on_user_id"
    t.check_constraint "gross_amount_cents IS NULL OR gross_amount_cents > 0", name: "corporate_action_imports_gross_positive"
    t.check_constraint "kind IS NULL OR kind IN ('dividend', 'jcp', 'split', 'reverse_split', 'share_bonus')", name: "corporate_action_imports_kind"
    t.check_constraint "net_amount_cents IS NULL OR net_amount_cents >= 0", name: "corporate_action_imports_net_nonnegative"
    t.check_constraint "ratio_denominator IS NULL OR ratio_denominator > 0", name: "corporate_action_imports_ratio_denominator_positive"
    t.check_constraint "ratio_numerator IS NULL OR ratio_numerator > 0", name: "corporate_action_imports_ratio_numerator_positive"
    t.check_constraint "source_reference <> ''", name: "corporate_action_imports_source_reference_present"
    t.check_constraint "status IN ('pending', 'ambiguous', 'confirmed', 'ignored', 'failed', 'conflict')", name: "corporate_action_imports_status"
    t.check_constraint "withholding_tax_cents IS NULL OR withholding_tax_cents >= 0", name: "corporate_action_imports_tax_nonnegative"
  end

  create_table "corporate_actions", force: :cascade do |t|
    t.integer "cash_in_lieu_amount_cents"
    t.decimal "cash_in_lieu_quantity", precision: 28, scale: 12
    t.datetime "created_at", null: false
    t.string "currency", limit: 3
    t.date "effective_on"
    t.date "ex_date"
    t.integer "gross_amount_cents"
    t.integer "institution_id"
    t.integer "instrument_id", null: false
    t.string "kind", null: false
    t.integer "net_amount_cents"
    t.text "notes"
    t.date "paid_on"
    t.integer "ratio_denominator"
    t.integer "ratio_numerator"
    t.text "raw_payload"
    t.string "slug", null: false
    t.string "source", limit: 64, default: "manual", null: false
    t.string "source_reference"
    t.string "status", default: "confirmed", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "withholding_tax_cents"
    t.index ["institution_id"], name: "index_corporate_actions_on_institution_id"
    t.index ["instrument_id"], name: "index_corporate_actions_on_instrument_id"
    t.index ["slug"], name: "index_corporate_actions_on_slug", unique: true
    t.index ["user_id", "instrument_id", "effective_on"], name: "index_corporate_actions_on_owner_instrument_effective_date"
    t.index ["user_id", "instrument_id", "paid_on"], name: "idx_on_user_id_instrument_id_paid_on_dc2d360a75"
    t.index ["user_id", "paid_on"], name: "index_corporate_actions_on_user_id_and_paid_on"
    t.index ["user_id", "source", "instrument_id", "source_reference"], name: "index_corporate_actions_on_owner_provider_reference", unique: true, where: "source_reference IS NOT NULL"
    t.index ["user_id"], name: "index_corporate_actions_on_user_id"
    t.check_constraint "( kind IN ('dividend', 'jcp') AND paid_on IS NOT NULL AND gross_amount_cents IS NOT NULL AND withholding_tax_cents IS NOT NULL AND net_amount_cents IS NOT NULL AND currency IS NOT NULL AND effective_on IS NULL AND ratio_numerator IS NULL AND ratio_denominator IS NULL AND cash_in_lieu_quantity IS NULL AND cash_in_lieu_amount_cents IS NULL ) OR ( kind IN ('split', 'reverse_split', 'share_bonus') AND paid_on IS NULL AND ex_date IS NULL AND gross_amount_cents IS NULL AND withholding_tax_cents IS NULL AND net_amount_cents IS NULL AND effective_on IS NOT NULL AND ratio_numerator IS NOT NULL AND ratio_denominator IS NOT NULL AND ( (cash_in_lieu_quantity IS NULL AND cash_in_lieu_amount_cents IS NULL AND currency IS NULL) OR (cash_in_lieu_quantity IS NOT NULL AND cash_in_lieu_amount_cents IS NOT NULL AND currency IS NOT NULL) ) )", name: "corporate_actions_subtype_shape"
    t.check_constraint "cash_in_lieu_amount_cents IS NULL OR cash_in_lieu_amount_cents >= 0", name: "corporate_actions_cash_in_lieu_amount_nonnegative"
    t.check_constraint "cash_in_lieu_quantity IS NULL OR cash_in_lieu_quantity > 0", name: "corporate_actions_cash_in_lieu_quantity_positive"
    t.check_constraint "ex_date IS NULL OR ex_date <= paid_on", name: "corporate_actions_ex_date_not_after_payment"
    t.check_constraint "gross_amount_cents > 0", name: "corporate_actions_gross_positive"
    t.check_constraint "kind <> 'jcp' OR currency = 'BRL'", name: "corporate_actions_jcp_currency"
    t.check_constraint "kind <> 'reverse_split' OR ratio_numerator < ratio_denominator", name: "corporate_actions_decreasing_ratio"
    t.check_constraint "kind IN ('dividend', 'jcp', 'split', 'reverse_split', 'share_bonus')", name: "corporate_actions_kind"
    t.check_constraint "kind NOT IN ('split', 'share_bonus') OR ratio_numerator > ratio_denominator", name: "corporate_actions_increasing_ratio"
    t.check_constraint "net_amount_cents = gross_amount_cents - withholding_tax_cents", name: "corporate_actions_amounts_reconcile"
    t.check_constraint "net_amount_cents >= 0", name: "corporate_actions_net_nonnegative"
    t.check_constraint "ratio_denominator IS NULL OR ratio_denominator BETWEEN 1 AND 9223372036854775807", name: "corporate_actions_ratio_denominator_bounded"
    t.check_constraint "ratio_numerator IS NULL OR ratio_numerator BETWEEN 1 AND 9223372036854775807", name: "corporate_actions_ratio_numerator_bounded"
    t.check_constraint "status IN ('pending', 'confirmed', 'ignored', 'reversed')", name: "corporate_actions_status"
    t.check_constraint "withholding_tax_cents >= 0", name: "corporate_actions_tax_nonnegative"
  end

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
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["slug"], name: "index_institutions_on_slug", unique: true
    t.index ["user_id", "name"], name: "index_institutions_on_user_id_and_name", unique: true
  end

  create_table "instrument_performance_materializations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "instrument_id", null: false
    t.string "reporting_currency", limit: 3, null: false
    t.date "requested_from"
    t.date "requested_to"
    t.integer "source_generation", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["instrument_id"], name: "index_instrument_performance_materializations_on_instrument_id"
    t.index ["user_id", "instrument_id", "reporting_currency"], name: "index_instrument_performance_materializations_uniqueness", unique: true
    t.index ["user_id"], name: "index_instrument_performance_materializations_on_user_id"
    t.check_constraint "(requested_from IS NULL AND requested_to IS NULL) OR (requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)", name: "instrument_performance_materializations_requested_range"
    t.check_constraint "source_generation >= 0", name: "instrument_performance_materializations_source_generation"
  end

  create_table "instrument_performance_observations", force: :cascade do |t|
    t.text "cash_flow_total", default: "0/1", null: false
    t.text "cost_basis_amount"
    t.datetime "created_at", null: false
    t.text "dated_cash_flow_total", default: "0/1", null: false
    t.datetime "generated_at", null: false
    t.integer "instrument_id", null: false
    t.text "invested_amount"
    t.text "investment_income_amount"
    t.text "market_value_amount"
    t.text "net_cash_flow_amount"
    t.date "observed_on", null: false
    t.text "realized_gain_amount"
    t.string "reporting_currency", limit: 3, null: false
    t.integer "source_generation", default: 0, null: false
    t.datetime "stale_at"
    t.string "status", null: false
    t.text "unrealized_gain_amount"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["instrument_id"], name: "index_instrument_performance_observations_on_instrument_id"
    t.index ["user_id", "instrument_id", "reporting_currency", "observed_on"], name: "index_instrument_performance_observations_uniqueness", unique: true
    t.index ["user_id"], name: "index_instrument_performance_observations_on_user_id"
    t.check_constraint "(status = 'missing' AND market_value_amount IS NULL AND cost_basis_amount IS NULL AND realized_gain_amount IS NULL AND unrealized_gain_amount IS NULL AND net_cash_flow_amount IS NULL AND investment_income_amount IS NULL AND invested_amount IS NULL) OR (status IN ('available', 'empty') AND market_value_amount IS NOT NULL AND cost_basis_amount IS NOT NULL AND realized_gain_amount IS NOT NULL AND unrealized_gain_amount IS NOT NULL AND net_cash_flow_amount IS NOT NULL AND investment_income_amount IS NOT NULL AND invested_amount IS NOT NULL)", name: "instrument_performance_observations_amounts_match_status"
    t.check_constraint "source_generation >= 0", name: "instrument_performance_observations_source_generation"
    t.check_constraint "status IN ('available', 'empty', 'missing')", name: "instrument_performance_observations_status"
  end

  create_table "instruments", force: :cascade do |t|
    t.string "asset_type", default: "other", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "BRL", null: false
    t.string "exchange", default: "BVMF", null: false, collation: "NOCASE"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "ticker", null: false, collation: "NOCASE"
    t.datetime "updated_at", null: false
    t.index ["asset_type"], name: "index_instruments_on_asset_type"
    t.index ["exchange", "ticker"], name: "index_instruments_on_exchange_and_ticker", unique: true
    t.index ["slug"], name: "index_instruments_on_slug", unique: true
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
    t.string "provider_identifier", null: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_market_benchmarks_on_identifier", unique: true
  end

  create_table "market_data_refreshes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error_class"
    t.string "error_message"
    t.datetime "finished_at"
    t.integer "processed_count", default: 0, null: false
    t.string "scope", null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.integer "total_count"
    t.datetime "updated_at", null: false
    t.index ["scope"], name: "index_market_data_refreshes_on_scope", unique: true
    t.index ["status"], name: "index_market_data_refreshes_on_status"
  end

  create_table "portfolio_performance_materializations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "reporting_currency", limit: 3, null: false
    t.date "requested_from"
    t.date "requested_to"
    t.integer "source_generation", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "reporting_currency"], name: "index_portfolio_performance_materializations_uniqueness", unique: true
    t.index ["user_id"], name: "index_portfolio_performance_materializations_on_user_id"
    t.check_constraint "(requested_from IS NULL AND requested_to IS NULL) OR (requested_from IS NOT NULL AND requested_to IS NOT NULL AND requested_from <= requested_to)", name: "portfolio_performance_materializations_requested_range"
    t.check_constraint "source_generation >= 0", name: "portfolio_performance_materializations_source_generation"
  end

  create_table "portfolio_performance_observations", force: :cascade do |t|
    t.text "cash_flow_total", default: "0/1", null: false
    t.datetime "created_at", null: false
    t.text "dated_cash_flow_total", default: "0/1", null: false
    t.datetime "generated_at", null: false
    t.text "market_value_amount"
    t.text "net_cash_flow_amount"
    t.date "observed_on", null: false
    t.string "reporting_currency", limit: 3, null: false
    t.integer "source_generation", default: 0, null: false
    t.datetime "stale_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id", "reporting_currency", "observed_on"], name: "index_portfolio_performance_observations_uniqueness", unique: true
    t.index ["user_id"], name: "index_portfolio_performance_observations_on_user_id"
    t.check_constraint "(status = 'missing' AND market_value_amount IS NULL AND net_cash_flow_amount IS NULL) OR (status IN ('available', 'empty') AND market_value_amount IS NOT NULL AND net_cash_flow_amount IS NOT NULL)", name: "portfolio_performance_observations_amounts_match_status"
    t.check_constraint "source_generation >= 0", name: "portfolio_performance_observations_source_generation"
    t.check_constraint "status IN ('available', 'empty', 'missing')", name: "portfolio_performance_observations_status"
  end

  create_table "position_materializations", force: :cascade do |t|
    t.decimal "average_unit_cost", precision: 50, scale: 24, default: "0.0", null: false
    t.datetime "calculated_at"
    t.integer "calculated_generation"
    t.decimal "cost_basis_amount", precision: 50, scale: 24, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_message"
    t.integer "instrument_id", null: false
    t.decimal "quantity", precision: 50, scale: 24, default: "0.0", null: false
    t.decimal "realized_gain_amount", precision: 50, scale: 24, default: "0.0", null: false
    t.integer "source_generation", default: 0, null: false
    t.integer "source_trade_id"
    t.datetime "source_trade_updated_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["instrument_id"], name: "index_position_materializations_on_instrument_id"
    t.index ["user_id", "instrument_id"], name: "index_position_materializations_on_user_and_instrument", unique: true
    t.index ["user_id"], name: "index_position_materializations_on_user_id"
    t.check_constraint "source_generation >= 0", name: "position_materializations_source_generation"
    t.check_constraint "status IN ('pending', 'refreshing', 'complete', 'failed')", name: "position_materializations_status"
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
    t.string "settlement_currency", limit: 3
    t.decimal "settlement_exchange_rate", precision: 28, scale: 12
    t.string "side", null: false
    t.string "slug", null: false
    t.date "traded_on", null: false
    t.decimal "unit_price", precision: 28, scale: 8, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["institution_id"], name: "index_trades_on_institution_id"
    t.index ["instrument_id"], name: "index_trades_on_instrument_id"
    t.index ["slug"], name: "index_trades_on_slug", unique: true
    t.index ["user_id", "instrument_id", "traded_on"], name: "index_trades_on_user_id_and_instrument_id_and_traded_on"
    t.index ["user_id", "traded_on"], name: "index_trades_on_user_id_and_traded_on"
    t.check_constraint "(settlement_currency IS NULL) = (settlement_exchange_rate IS NULL)", name: "trades_settlement_conversion_complete"
    t.check_constraint "fees_cents >= 0", name: "trades_fees_nonnegative"
    t.check_constraint "quantity > 0", name: "trades_quantity_positive"
    t.check_constraint "settlement_currency IS NULL OR settlement_currency <> currency", name: "trades_settlement_currency_distinct"
    t.check_constraint "settlement_currency IS NULL OR settlement_currency GLOB '[A-Z][A-Z][A-Z]'", name: "trades_settlement_currency_format"
    t.check_constraint "settlement_exchange_rate IS NULL OR settlement_exchange_rate > 0", name: "trades_settlement_exchange_rate_positive"
    t.check_constraint "side IN ('buy', 'sell')", name: "trades_side_check"
    t.check_constraint "unit_price > 0", name: "trades_unit_price_positive"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.string "reporting_currency", limit: 3, default: "BRL", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.check_constraint "reporting_currency GLOB '[A-Z][A-Z][A-Z]'", name: "users_reporting_currency_format"
  end

  add_foreign_key "corporate_action_import_scans", "instruments"
  add_foreign_key "corporate_action_import_scans", "users"
  add_foreign_key "corporate_action_imports", "corporate_actions", on_delete: :nullify
  add_foreign_key "corporate_action_imports", "institutions"
  add_foreign_key "corporate_action_imports", "instruments"
  add_foreign_key "corporate_action_imports", "users"
  add_foreign_key "corporate_actions", "institutions"
  add_foreign_key "corporate_actions", "instruments"
  add_foreign_key "corporate_actions", "users"
  add_foreign_key "daily_closing_prices", "instruments"
  add_foreign_key "historical_data_backfills", "instruments"
  add_foreign_key "institutions", "users"
  add_foreign_key "instrument_performance_materializations", "instruments"
  add_foreign_key "instrument_performance_materializations", "users"
  add_foreign_key "instrument_performance_observations", "instruments"
  add_foreign_key "instrument_performance_observations", "users"
  add_foreign_key "market_benchmark_observations", "market_benchmarks"
  add_foreign_key "portfolio_performance_materializations", "users"
  add_foreign_key "portfolio_performance_observations", "users"
  add_foreign_key "position_materializations", "instruments"
  add_foreign_key "position_materializations", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "trades", "institutions"
  add_foreign_key "trades", "instruments"
  add_foreign_key "trades", "users"
end
