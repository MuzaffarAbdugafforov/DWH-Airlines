# DWH Airlines

A 5-layer data warehouse built on the PostgresPro `demo` (airlines) database, with hand-written SQL / PL/pgSQL ETL.

Layers: SOURCE (`bookings`) -> RAW -> STG -> ODS -> DDS -> DM, plus an `etl` schema for audit logs and DQ results.

## Structure

| Path | Content |
|---|---|
| `sql/00_schemas.sql` | Schema creation |
| `sql/01_etl_tables.sql` | `etl.etl_runs`, `etl.etl_step_logs`, `etl.etl_dq_results` |
| `sql/02_raw.sql` | RAW tables (exact source copy + technical columns) and RAW load procedures |
| `analysis/source_profiling.sql` | Source data profiling queries |
| `docs/ER-Airlines.png` | Source ER diagram |

## Run order

```
00_schemas.sql -> 01_etl_tables.sql -> 02_raw.sql
```

Status: work in progress (RAW layer).
