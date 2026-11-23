-- stg layer

-- =====================================================================
-- ПЛАН STG (реализуем после создания ODS)
-- =====================================================================
--
-- ТЗ п.3: приведение типов, именований, дат и форматов; явная обработка
--         NULL, дублей и некорректных значений с журналом отклонений.
-- ТЗ п.2: в STG минимум 6 основных таблиц.
-- ТЗ п.6: полная загрузка, затем инкременты через сравнение ключей / хешей;
--         небезопасные строки -> карантин, не удалять молча; идемпотентность.
--
-- 1. ТАБЛИЦЫ (не решено: все 9 или только 6 обязательных)
--    обязательные: bookings, tickets, segments, flights, boarding_passes, routes
--    нужны для KPI: seats (загрузка мест), airports_data, airplanes_data
--
-- 2. ПРЕОБРАЗОВАНИЯ
--    airports_data  -> stg.airports:  jsonb -> airport_name_en/ru, city_en/ru, country_en/ru;
--                                     coordinates (point) -> longitude, latitude
--    airplanes_data -> stg.airplanes: model jsonb -> model_en / model_ru
--    routes: validity (tstzrange) -> valid_from / valid_to
--            (704 route_no, 1162 строки, 4 месячных периода)
--    остальные: колонки и типы как есть, trim() для текста
--
-- 3. FULL / INCREMENTAL  (поток: RAW -> STG -> ODS)
--    STG очищается в начале каждого запуска и хранит только текущий пакет.
--    Предыдущее состояние берётся из ODS (сравнение по ключу и row_hash):
--      FULL:        все строки из RAW, change_type = 'I'
--      INCREMENTAL: ключа нет в ODS          -> change_type = 'I' (новая)
--                   ключ есть, row_hash другой -> change_type = 'U' (изменённая)
--                   ключ и row_hash совпадают  -> пропускаем
--    row_hash передаётся дальше RAW -> STG -> ODS.
--    Удаления не обрабатываем (в тестовых сценариях ТЗ их нет).
--    Служебные поля STG: run_id, step_id, row_hash, change_type, loaded_at.
--    Зависимость: таблицы ODS (бизнес-ключ + row_hash) должны существовать.
--
-- 4. КАРАНТИН (etl.etl_quarantine создаём в начале STG, структура из etl_lab)
--    некорректные строки -> etl.etl_quarantine (row_data = to_jsonb(r), rule_code, reject_reason),
--    в STG не попадают; сверка в каждом загрузчике: read = inserted + rejected.
--      DQ_STG_001  бизнес-ключ NULL                                    все таблицы
--      DQ_STG_002  дубль бизнес-ключа (в карантин все копии)            все таблицы
--      DQ_STG_003  price NULL или < 0                                   segments
--      DQ_STG_004  fare_conditions не in (Economy, Comfort, Business)   segments, seats
--      DQ_STG_005  scheduled_arrival < scheduled_departure, или
--                  actual_arrival < actual_departure (если оба заполнены) flights
--      DQ_STG_006  status не in (Scheduled, On Time, Delayed, Boarding,
--                  Departed, Arrived, Cancelled)                        flights
--
-- 5. DQ В etl_dq_results: etl.check_stg(p_run_id), просто как check_raw
--    - по каждой таблице: число строк в карантине по каждому правилу в этом запуске
--    - только для FULL: сверка суммы price  RAW = STG + карантин (как DQ006 в etl_lab)
--
-- 6. ОСОБЕННОСТИ ДАННЫХ (не ошибки)
--    boarding_passes: 30 360 строк без boarding_no / boarding_time - талон выдан,
--      посадки не было; для загрузки мест считать только boarding_time is not null.
--    flights: ~10 800 рейсов без фактических времён (Scheduled и т.п.) - норма,
--      DQ_STG_005 проверяет actual только если оба заполнены.
--
-- Проверки между таблицами (ссылочная целостность, validity маршрута,
-- посадки <= вместимость, сверка сумм SOURCE <-> DDS <-> DM) - в ODS / DDS / DM.
-- =====================================================================


-- =====================================================================
-- STG DDL
-- =====================================================================
-- Формат как в etl_lab (stg.customers, stg.sales):
--   - типизированные колонки, NOT NULL, PK на бизнес-ключе;
--   - CHECK-ограничения повторяют правила карантина (последняя защита:
--     если строка прошла мимо карантина, insert упадёт, а не загрузит мусор).
-- Бизнес-колонки = колонки ODS (уже разобранные jsonb / point / tstzrange).
-- Служебные колонки (ТЗ п.6, план п.3):
--   row_hash    - хеш из RAW без пересчёта, по нему сравниваем с ODS;
--   change_type - 'I' новая строка, 'U' изменённая;
--   run_id, step_id, loaded_at.
-- FK в STG нет (как в etl_lab): связи проверяются в ODS.


--drop table if exists stg.airports;
--drop table if exists stg.airplanes;
--drop table if exists stg.seats;
--drop table if exists stg.routes;
--drop table if exists stg.flights;
--drop table if exists stg.bookings;
--drop table if exists stg.tickets;
--drop table if exists stg.segments;
--drop table if exists stg.boarding_passes;


-- =====================================================================
-- Справочники
-- =====================================================================

-- аэропорты: airport_name/city/country jsonb ->> 'en'/'ru', coordinates[0]/[1]
create table if not exists stg.airports (
	airport_code char(3) not null,
	airport_name_en text not null,
	airport_name_ru text not null,
	city_en text not null,
	city_ru text not null,
	country_en text not null,
	country_ru text not null,
	longitude double precision not null,
	latitude double precision not null,
	timezone text not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_airports primary key (airport_code),
	constraint ck_stg_airports_change_type check (change_type in ('I', 'U'))
);


-- самолёты: model jsonb ->> 'en'/'ru'
create table if not exists stg.airplanes (
	airplane_code char(3) not null,
	model_en text not null,
	model_ru text not null,
	range integer not null,
	speed integer not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_airplanes primary key (airplane_code),
	constraint ck_stg_airplanes_change_type check (change_type in ('I', 'U'))
);


-- места
create table if not exists stg.seats (
	airplane_code char(3) not null,
	seat_no text not null,
	fare_conditions text not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_seats primary key (airplane_code, seat_no),
	constraint ck_stg_seats_change_type check (change_type in ('I', 'U')),
	-- DQ_STG_004
	constraint ck_stg_seats_fare_conditions
		check (fare_conditions in ('Economy', 'Comfort', 'Business'))
);


-- маршруты: validity tstzrange -> lower() = valid_from, upper() = valid_to, период [valid_from, valid_to)
create table if not exists stg.routes (
	route_no text not null,
	valid_from timestamptz not null,
	valid_to timestamptz not null,
	departure_airport char(3) not null,
	arrival_airport char(3) not null,
	airplane_code char(3) not null,
	days_of_week integer[] not null,
	scheduled_time time not null,
	duration interval not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_routes primary key (route_no, valid_from),
	constraint ck_stg_routes_change_type check (change_type in ('I', 'U'))
);


-- =====================================================================
-- Операционные сущности
-- =====================================================================

-- рейсы (actual_* могут быть NULL - рейс ещё не выполнен)
create table if not exists stg.flights (
	flight_id integer not null,
	route_no text not null,
	status text not null,
	scheduled_departure timestamptz not null,
	scheduled_arrival timestamptz not null,
	actual_departure timestamptz,
	actual_arrival timestamptz,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_flights primary key (flight_id),
	constraint ck_stg_flights_change_type check (change_type in ('I', 'U')),
	-- DQ_STG_005 (NULL в actual_* даёт unknown -> CHECK проходит, это и нужно)
	constraint ck_stg_flights_scheduled_dates
		check (scheduled_arrival >= scheduled_departure),
	constraint ck_stg_flights_actual_dates
		check (actual_arrival >= actual_departure),
	-- DQ_STG_006
	constraint ck_stg_flights_status
		check (status in ('Scheduled', 'On Time', 'Delayed', 'Boarding', 'Departed', 'Arrived', 'Cancelled'))
);


-- бронирования
create table if not exists stg.bookings (
	book_ref char(6) not null,
	book_date timestamptz not null,
	total_amount numeric(10, 2) not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_bookings primary key (book_ref),
	constraint ck_stg_bookings_change_type check (change_type in ('I', 'U'))
);


-- билеты
create table if not exists stg.tickets (
	ticket_no text not null,
	book_ref char(6) not null,
	passenger_id text not null,
	passenger_name text not null,
	outbound boolean not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_tickets primary key (ticket_no),
	constraint ck_stg_tickets_change_type check (change_type in ('I', 'U'))
);


-- перелёты в составе билета
create table if not exists stg.segments (
	ticket_no text not null,
	flight_id integer not null,
	fare_conditions text not null,
	price numeric(10, 2) not null,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_segments primary key (ticket_no, flight_id),
	constraint ck_stg_segments_change_type check (change_type in ('I', 'U')),
	-- DQ_STG_003
	constraint ck_stg_segments_price check (price >= 0),
	-- DQ_STG_004
	constraint ck_stg_segments_fare_conditions
		check (fare_conditions in ('Economy', 'Comfort', 'Business'))
);


-- посадочные талоны (boarding_no / boarding_time NULL = посадки не было)
create table if not exists stg.boarding_passes (
	ticket_no text not null,
	flight_id integer not null,
	seat_no text not null,
	boarding_no integer,
	boarding_time timestamptz,

	row_hash varchar(32) not null,
	change_type char(1) not null,
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),

	constraint pk_stg_boarding_passes primary key (ticket_no, flight_id),
	constraint ck_stg_boarding_passes_change_type check (change_type in ('I', 'U'))
);
