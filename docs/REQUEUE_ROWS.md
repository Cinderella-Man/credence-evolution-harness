# Re-queue rows, resolved to task NAMES

Row indices are positional (`Path.wildcard |> Enum.sort`) and the dataset has
grown since the run: the `0*01` glob matched **230** dirs then and **282** now,
so index 225 no longer names the task it named. The mapping was never lost —
`var/run/rows.jsonl` records `task` beside `index` for every row — so this file
materialises it for the rows the re-queue list names, and those names are
stable under further dataset growth.

`present?` is whether the task dir still exists in the dataset today.

## diverged (re-queue)

* row 1 — `001_002_fixed_window_counter_01` (present? yes)
* row 7 — `002_004_leaky_bucket_failure_cb_01` (present? yes)
* row 18 — `005_003_replayeventbus_01` (present? yes)
* row 106 — `033_002_metrics_file_aggregator_01` (present? yes)
* row 107 — `033_003_http_access_log_analyzer_01` (present? yes)
* row 162 — `063_001_concurrent_data_fetcher_with_timeout_01` (present? yes)
* row 164 — `063_003_fallback_chain_concurrent_fetcher_01` (present? yes)
* row 205 — `078_001_ring_buffer_01` (present? yes)

## diverged (after T3.4 — now landed)

* row 31 — `008_004_observed_remove_set_crdt_01` (present? yes)
* row 33 — `009_002_write_behind_batch_coalescer_01` (present? yes)
* row 185 — `072_004_scripted_sequence_clock_01` (present? yes)

## escalated

* row 2 — `001_003_hierarchical_limiter_01` (present? yes)
* row 6 — `002_003_progressive_recovery_cb_01` (present? yes)
* row 95 — `025_003_coalescing_batch_long_poll_with_linger_window_01` (present? yes)
* row 100 — `031_004_logfmt_record_validator_with_hand_written_parser_01` (present? yes)
* row 119 — `037_002_path_addressed_nested_record_anonymizer_01` (present? yes)
* row 144 — `043_003_sliding_window_time_decayed_leaderboard_01` (present? yes)
* row 169 — `064_004_instrumented_work_stealing_queue_with_steal_metrics_01` (present? yes)
* row 225 — `095_004_multi_currency_money_with_fx_conversion_01` (present? yes)

## classifier_errors

* row 1 — `001_002_fixed_window_counter_01` (present? yes)
* row 23 — `006_004_swrcache_01` (present? yes)
* row 125 — `038_004_diagnostic_tree_validator_with_best_effort_repair_01` (present? yes)
* row 138 — `042_001_ets_based_write_through_cache_layer_01` (present? yes)
* row 139 — `042_002_failure_aware_write_through_cache_with_negative_caching_01` (present? yes)
* row 141 — `042_004_single_flight_non_blocking_write_through_cache_01` (present? yes)
* row 203 — `077_002_deletable_interval_tree_01` (present? yes)
* row 227 — `097_001_password_policy_enforcer_01` (present? yes)

## the run's one ACCEPT

* row 199 — `076_002_compressed_radix_trie_with_path_compression_01` (present? yes)
