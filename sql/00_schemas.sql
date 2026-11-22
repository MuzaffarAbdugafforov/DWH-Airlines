-- DWH schemas (TZ: SOURCE -> RAW -> STG -> ODS -> DDS -> DM)
-- SOURCE = schema bookings of the demo database
create schema if not exists etl;
create schema if not exists raw;
create schema if not exists stg;
create schema if not exists ods;
create schema if not exists dds;
create schema if not exists dm;
