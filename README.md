# DWH Airlines

A 5-layer data warehouse built on the PostgresPro `demo` (airlines) database, with hand-written SQL / PL/pgSQL ETL.

Layers: SOURCE (`bookings`) -> RAW -> STG -> ODS -> DDS -> DM, plus an `etl` schema for audit logs, quarantine and DQ results.

## Structure

| Path | Content |
|---|---|
| `sql/00_schemas.sql` | Schema creation (`etl`, `raw`, `stg`, `ods`, `dds`, `dm`) |
| `sql/01_etl_tables.sql` | `etl.etl_runs`, `etl.etl_step_logs`, `etl.etl_dq_results`, `etl.etl_quarantine` |
| `sql/02_raw.sql` | RAW tables (exact source copy + technical columns), RAW load procedures, RAW DQ (`etl.check_raw`) |
| `sql/03_stg.sql` | STG tables, STG loaders (typing, NULL/duplicate handling, quarantine), STG DQ (`etl.check_stg`) |
| `sql/04_ods.sql` | ODS tables on business keys, ODS loaders (insert / update), ODS DQ (`etl.check_ods`) |
| `sql/05_dds.sql` | DDS facts and dimensions (incl. `dim_route_scd2`), DDS loaders, DDS DQ (`etl.check_dds`) |
| `sql/06_dm.sql` | DM marts `dm_sales_routes`, `dm_flight_performance` and their loaders |
| `analysis/source_profiling.sql` | Source data profiling queries |
| `docs/ER-Airlines.png` | Source ER diagram |

## Run order

```
00_schemas.sql -> 01_etl_tables.sql -> 02_raw.sql -> 03_stg.sql -> 04_ods.sql -> 05_dds.sql -> 06_dm.sql
```

Load order inside one run: RAW -> `etl.check_raw` -> STG -> `etl.check_stg` -> ODS -> `etl.check_ods` -> DDS -> `etl.check_dds` -> DM.

## Data Quality rules

Results are stored in `etl.etl_dq_results` (run, rule, rows checked, violations, sample keys). Rows rejected in STG go to `etl.etl_quarantine` (never deleted silently).

| Rule | Layer | Severity | Check | Tables | Handling |
|---|---|---|---|---|---|
| DQ_RAW_001 | RAW | CRITICAL | Row count SOURCE = RAW | all 9 tables | logged |
| DQ_RAW_005 | RAW | CRITICAL | Amount sum SOURCE = RAW | `bookings.total_amount`, `segments.price` | logged |
| DQ_STG_001 | STG | ERROR | Business key is NULL | all tables | quarantine |
| DQ_STG_002 | STG | ERROR | Duplicate business key (all copies quarantined) | all tables | quarantine |
| DQ_STG_003 | STG | ERROR | `price` is NULL or < 0 | segments | quarantine |
| DQ_STG_004 | STG | ERROR | `fare_conditions` NULL or not in (Economy, Comfort, Business) | segments, seats | quarantine |
| DQ_STG_005 | STG | ERROR | `scheduled_arrival < scheduled_departure`, or `actual_arrival < actual_departure` (when both filled) | flights | quarantine |
| DQ_STG_006 | STG | ERROR | `status` NULL or not in (Scheduled, On Time, Delayed, Boarding, Departed, Arrived, Cancelled) | flights | quarantine |
| DQ_STG_007 | STG | — | Orphan rows (reserved, not implemented: orphans fail the ODS foreign key -> step FAILED -> fix and restart) | — | — |
| DQ_STG_008 | STG | CRITICAL | Sum RAW = STG + quarantine (FULL load only) | `segments.price`, `bookings.total_amount` | logged |
| DQ_ODS_001 | ODS | CRITICAL | Flight matches exactly one route version (`scheduled_departure >= valid_from and < valid_to`) | ods_flight / ods_route | logged |
| DQ_ODS_002 | ODS | ERROR | Boardings (`boarding_time is not null`) <= seat capacity of the airplane of the valid route version | ods_boarding_pass | logged |
| DQ_DDS_001 | DDS | CRITICAL | SCD2 versions of one route period do not overlap in `[valid_from, valid_to)` | dim_route_scd2 | logged |
| DQ_DDS_002 | DDS | CRITICAL | Each route period has exactly one current SCD2 version (`is_current`) | dim_route_scd2 | logged |
| DQ_DDS_003 | DDS | CRITICAL | `SUM(price)` SOURCE = `fact_ticket_segment` + quarantined segments of the run | fact_ticket_segment | logged |

Constraints that back these rules: PK / unique keys on business keys (e.g. `ticket_no + flight_id` in segments and boarding passes), FKs between ODS tables (segment -> flight, ticket -> booking, ...), CHECKs in STG.

DM reconciliation (inside the DM loaders, step FAILED on mismatch):
- `dm.load_sales_routes`: `SUM(segments_cnt)` in the mart = row count of `dds.fact_ticket_segment` (no rows lost or duplicated by JOINs).
- `dm.load_flight_performance`: `SUM(flights_cnt)` in the mart = row count of `dds.fact_flight`.

Mapping to the domain checks of the TZ (§7):

| TZ check | Covered by |
|---|---|
| Uniqueness of (ticket_no, flight_id) in segments and boarding_passes | DQ_STG_002 + PK |
| `price >= 0` and valid `fare_conditions` | DQ_STG_003, DQ_STG_004 |
| `flight_id` of a segment exists; route joined by validity interval | FK segment -> flight, DQ_ODS_001 |
| `scheduled_arrival >= scheduled_departure`, consistent actual times | DQ_STG_005 |
| Boardings <= airplane capacity | DQ_ODS_002 |
| Segment sum SOURCE <-> DDS <-> DM without JOIN double counting | DQ_RAW_005, DQ_STG_008, DQ_DDS_003, DM reconciliation |

## Data marts (DM)

Both marts are built only from DDS, fully recalculated on each run (truncate + insert, idempotent). All dates are UTC.

### `dm.dm_sales_routes`

Grain: booking date x route (`route_no`) x fare class (`fare_conditions`). Key: `(book_date, route_no, fare_conditions)`.

| KPI | Formula |
|---|---|
| `revenue` | `SUM(segments.price)` by booking date (`bookings.total_amount` is not added) |
| `tickets_cnt` | `COUNT(DISTINCT ticket_no)` — not additive across routes |
| `segments_cnt` | number of flight segments `(ticket_no, flight_id)` |
| `avg_segment_price` | `revenue / segments_cnt` (in BI: `SUM(revenue) / SUM(segments_cnt)`) |

Questions it answers:
- How much revenue was sold per day / period?
- Which routes (and departure/arrival cities) bring the most revenue — top routes?
- How is revenue split between Economy, Comfort and Business?
- How many tickets and flight segments were sold per period, route and class?
- What is the average segment price per route and class?

### `dm.dm_flight_performance`

Grain: flight date (`scheduled_departure`, UTC) x route (`route_no`) x flight status. Key: `(flight_date, route_no, status)`.

| KPI | Formula |
|---|---|
| `flights_cnt` | all flights |
| `departed_cnt` | flights with known `actual_departure` (future / cancelled flights excluded) |
| `delayed_cnt` | departed flights with `actual_departure > scheduled_departure + 15 min` |
| `delay_share` | `delayed_cnt / departed_cnt` |
| `boardings_cnt` | confirmed boardings (`boarding_time is not null`) of departed flights |
| `seats_cnt` | airplane seats of departed flights |
| `load_factor` | `boardings_cnt / seats_cnt` — only departed flights with known seat count |

In BI, shares are calculated as `SUM(numerator) / SUM(denominator)`, not as an average of the stored shares.

Questions it answers:
- How many flights were scheduled and actually performed per day / period?
- How are flights distributed by status?
- What share of performed flights was delayed by more than 15 minutes, per route and departure airport?
- How many passengers actually boarded?
- What is the seat load factor per route, airport and period?
- Which departure airports have the most flights / delays?

Status: work in progress (orchestrator, Superset dashboards and documentation next).
