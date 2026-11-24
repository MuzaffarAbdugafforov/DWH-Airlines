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
--   Причина: STG хранит только текущий пакет. При INCREMENTAL родитель новой
--   строки обычно уже в ODS, а не в STG (новый билет -> старое бронирование),
--   поэтому FK внутри STG отклонял бы корректные строки.
--   Решение (вариант 1): строка-сирота (нет родителя) падает на FK в ODS ->
--   этап ODS FAILED -> запуск FAILED -> исправление и перезапуск (ТЗ п.6).
--   Мягкую проверку "родитель есть в STG или ODS" (DQ_STG_007 -> карантин)
--   можно добавить позже, если понадобится для тестов.


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


-- =====================================================================
-- STG загрузчики
-- =====================================================================
-- Шаблон как в etl_lab (stg.load_customers) + стиль RAW (truncate, error_message в etl_step_logs).
-- ТЗ п.3: приведение форматов, обработка NULL и дублей с журналом отклонений.
-- ТЗ п.6: инкремент через сравнение ключа и row_hash с ODS; карантин; идемпотентность
--         (STG очищается в начале -> повторный запуск даёт тот же результат).
--
-- Пакет (delta) = строки RAW, которые надо передать в ODS:
--   FULL:        все строки RAW                                  -> change_type 'I'
--   INCREMENTAL: ключа нет в ODS                                 -> change_type 'I'
--                ключ есть в ODS, но row_hash отличается         -> change_type 'U'
--                (ключ и row_hash совпадают -> строка не попадает в пакет)
-- Тип загрузки берём из etl.etl_runs по p_run_id.
-- rows_read = размер пакета; сверка: read = inserted + rejected.


-- аэропорты: raw.airports_data -> stg.airports
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа, в карантин все копии)
create or replace procedure stg.load_airports(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.airports', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.airports_data r
			left join ods.ods_airport o
				on o.airport_code = r.airport_code
			where v_load_type = 'FULL'
				or o.airport_code is null
				or o.row_hash <> r.row_hash;

			truncate stg.airports;

			-- корректные строки
			insert into stg.airports (
				airport_code,
				airport_name_en,
				airport_name_ru,
				city_en,
				city_ru,
				country_en,
				country_ru,
				longitude,
				latitude,
				timezone,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.airport_code,
				trim(r.airport_name ->> 'en'),
				trim(r.airport_name ->> 'ru'),
				trim(r.city ->> 'en'),
				trim(r.city ->> 'ru'),
				trim(r.country ->> 'en'),
				trim(r.country ->> 'ru'),
				r.coordinates[0],	-- point (x, y): x = долгота
				r.coordinates[1],	-- y = широта
				trim(r.timezone),
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.airport_code) as key_cnt,
					case
						when v_load_type = 'FULL' or o.airport_code is null then 'I'
						else 'U'
					end as change_type
				from raw.airports_data r
				left join ods.ods_airport o
					on o.airport_code = r.airport_code
				where v_load_type = 'FULL'
					or o.airport_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airport_code is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.airports_data',
				to_jsonb(r) - 'key_cnt',
				case
					when r.airport_code is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.airport_code is null then 'airport_code is NULL'
					when r.key_cnt > 1 then 'Duplicate airport_code'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.airport_code) as key_cnt
				from raw.airports_data r
				left join ods.ods_airport o
					on o.airport_code = r.airport_code
				where v_load_type = 'FULL'
					or o.airport_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airport_code is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- ---------------------------------------------------------------------
-- Остальные 8 загрузчиков - тот же шаблон, что stg.load_airports.
-- Отличия по таблицам: ключ, преобразования, дополнительные правила карантина.
-- NULL в проверяемых полях (price, fare_conditions, status) -> тоже карантин
-- (иначе not in (...) даёт NULL, строка не попадёт ни в STG, ни в карантин).
-- Ключевые поля и коды-домены не trim-уем: ключ должен совпадать с ODS,
-- а значение с пробелами - некорректное, его не исправляем молча, а в карантин.
-- ---------------------------------------------------------------------


-- самолёты: raw.airplanes_data -> stg.airplanes
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа)
create or replace procedure stg.load_airplanes(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.airplanes', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.airplanes_data r
			left join ods.ods_airplane o
				on o.airplane_code = r.airplane_code
			where v_load_type = 'FULL'
				or o.airplane_code is null
				or o.row_hash <> r.row_hash;

			truncate stg.airplanes;

			-- корректные строки
			insert into stg.airplanes (
				airplane_code,
				model_en,
				model_ru,
				range,
				speed,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.airplane_code,
				trim(r.model ->> 'en'),
				trim(r.model ->> 'ru'),
				r.range,
				r.speed,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.airplane_code) as key_cnt,
					case
						when v_load_type = 'FULL' or o.airplane_code is null then 'I'
						else 'U'
					end as change_type
				from raw.airplanes_data r
				left join ods.ods_airplane o
					on o.airplane_code = r.airplane_code
				where v_load_type = 'FULL'
					or o.airplane_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airplane_code is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.airplanes_data',
				to_jsonb(r) - 'key_cnt',
				case
					when r.airplane_code is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.airplane_code is null then 'airplane_code is NULL'
					when r.key_cnt > 1 then 'Duplicate airplane_code'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.airplane_code) as key_cnt
				from raw.airplanes_data r
				left join ods.ods_airplane o
					on o.airplane_code = r.airplane_code
				where v_load_type = 'FULL'
					or o.airplane_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airplane_code is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- места: raw.seats -> stg.seats
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа),
--                    DQ_STG_004 (fare_conditions NULL или не Economy/Comfort/Business)
create or replace procedure stg.load_seats(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.seats', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.seats r
			left join ods.ods_seat o
				on o.airplane_code = r.airplane_code
				and o.seat_no = r.seat_no
			where v_load_type = 'FULL'
				or o.airplane_code is null
				or o.row_hash <> r.row_hash;

			truncate stg.seats;

			-- корректные строки
			insert into stg.seats (
				airplane_code,
				seat_no,
				fare_conditions,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.airplane_code,
				r.seat_no,
				r.fare_conditions,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.airplane_code, r.seat_no) as key_cnt,
					case
						when v_load_type = 'FULL' or o.airplane_code is null then 'I'
						else 'U'
					end as change_type
				from raw.seats r
				left join ods.ods_seat o
					on o.airplane_code = r.airplane_code
					and o.seat_no = r.seat_no
				where v_load_type = 'FULL'
					or o.airplane_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airplane_code is not null
				and r.seat_no is not null
				and r.key_cnt = 1
				and r.fare_conditions in ('Economy', 'Comfort', 'Business');

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.seats',
				to_jsonb(r) - 'key_cnt',
				case
					when r.airplane_code is null or r.seat_no is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
					else 'DQ_STG_004'
				end,
				case
					when r.airplane_code is null or r.seat_no is null then 'airplane_code or seat_no is NULL'
					when r.key_cnt > 1 then 'Duplicate airplane_code + seat_no'
					else 'Invalid fare_conditions'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.airplane_code, r.seat_no) as key_cnt
				from raw.seats r
				left join ods.ods_seat o
					on o.airplane_code = r.airplane_code
					and o.seat_no = r.seat_no
				where v_load_type = 'FULL'
					or o.airplane_code is null
					or o.row_hash <> r.row_hash
			) r
			where r.airplane_code is null
				or r.seat_no is null
				or r.key_cnt > 1
				or r.fare_conditions is null
				or r.fare_conditions not in ('Economy', 'Comfort', 'Business');

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- маршруты: raw.routes -> stg.routes
-- validity -> valid_from = lower(), valid_to = upper(); ключ = route_no + valid_from
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа)
create or replace procedure stg.load_routes(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.routes', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.routes r
			left join ods.ods_route o
				on o.route_no = r.route_no
				and o.valid_from = lower(r.validity)
			where v_load_type = 'FULL'
				or o.route_no is null
				or o.row_hash <> r.row_hash;

			truncate stg.routes;

			-- корректные строки
			insert into stg.routes (
				route_no,
				valid_from,
				valid_to,
				departure_airport,
				arrival_airport,
				airplane_code,
				days_of_week,
				scheduled_time,
				duration,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.route_no,
				lower(r.validity),
				upper(r.validity),
				r.departure_airport,
				r.arrival_airport,
				r.airplane_code,
				r.days_of_week,
				r.scheduled_time,
				r.duration,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.route_no, lower(r.validity)) as key_cnt,
					case
						when v_load_type = 'FULL' or o.route_no is null then 'I'
						else 'U'
					end as change_type
				from raw.routes r
				left join ods.ods_route o
					on o.route_no = r.route_no
					and o.valid_from = lower(r.validity)
				where v_load_type = 'FULL'
					or o.route_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.route_no is not null
				and lower(r.validity) is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.routes',
				to_jsonb(r) - 'key_cnt',
				case
					when r.route_no is null or lower(r.validity) is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.route_no is null or lower(r.validity) is null then 'route_no or valid_from is NULL'
					when r.key_cnt > 1 then 'Duplicate route_no + valid_from'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.route_no, lower(r.validity)) as key_cnt
				from raw.routes r
				left join ods.ods_route o
					on o.route_no = r.route_no
					and o.valid_from = lower(r.validity)
				where v_load_type = 'FULL'
					or o.route_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.route_no is null
				or lower(r.validity) is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- рейсы: raw.flights -> stg.flights
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа),
--   DQ_STG_005 (scheduled_arrival < scheduled_departure или actual_arrival < actual_departure),
--   DQ_STG_006 (status NULL или не из списка)
-- (actual_arrival >= actual_departure) is not false: если actual_* NULL (рейс не выполнен) - строка корректна
create or replace procedure stg.load_flights(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.flights', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.flights r
			left join ods.ods_flight o
				on o.flight_id = r.flight_id
			where v_load_type = 'FULL'
				or o.flight_id is null
				or o.row_hash <> r.row_hash;

			truncate stg.flights;

			-- корректные строки
			insert into stg.flights (
				flight_id,
				route_no,
				status,
				scheduled_departure,
				scheduled_arrival,
				actual_departure,
				actual_arrival,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.flight_id,
				r.route_no,
				r.status,
				r.scheduled_departure,
				r.scheduled_arrival,
				r.actual_departure,
				r.actual_arrival,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.flight_id) as key_cnt,
					case
						when v_load_type = 'FULL' or o.flight_id is null then 'I'
						else 'U'
					end as change_type
				from raw.flights r
				left join ods.ods_flight o
					on o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.flight_id is null
					or o.row_hash <> r.row_hash
			) r
			where r.flight_id is not null
				and r.key_cnt = 1
				and r.scheduled_arrival >= r.scheduled_departure
				and (r.actual_arrival >= r.actual_departure) is not false
				and r.status in ('Scheduled', 'On Time', 'Delayed', 'Boarding', 'Departed', 'Arrived', 'Cancelled');

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.flights',
				to_jsonb(r) - 'key_cnt',
				case
					when r.flight_id is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
					when r.scheduled_arrival < r.scheduled_departure
						or r.actual_arrival < r.actual_departure then 'DQ_STG_005'
					else 'DQ_STG_006'
				end,
				case
					when r.flight_id is null then 'flight_id is NULL'
					when r.key_cnt > 1 then 'Duplicate flight_id'
					when r.scheduled_arrival < r.scheduled_departure
						or r.actual_arrival < r.actual_departure then 'Arrival before departure'
					else 'Invalid status'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.flight_id) as key_cnt
				from raw.flights r
				left join ods.ods_flight o
					on o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.flight_id is null
					or o.row_hash <> r.row_hash
			) r
			where r.flight_id is null
				or r.key_cnt > 1
				or r.scheduled_arrival < r.scheduled_departure
				or r.actual_arrival < r.actual_departure
				or r.status is null
				or r.status not in ('Scheduled', 'On Time', 'Delayed', 'Boarding', 'Departed', 'Arrived', 'Cancelled');

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- бронирования: raw.bookings -> stg.bookings
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа)
create or replace procedure stg.load_bookings(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.bookings', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.bookings r
			left join ods.ods_booking o
				on o.book_ref = r.book_ref
			where v_load_type = 'FULL'
				or o.book_ref is null
				or o.row_hash <> r.row_hash;

			truncate stg.bookings;

			-- корректные строки
			insert into stg.bookings (
				book_ref,
				book_date,
				total_amount,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.book_ref,
				r.book_date,
				r.total_amount,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.book_ref) as key_cnt,
					case
						when v_load_type = 'FULL' or o.book_ref is null then 'I'
						else 'U'
					end as change_type
				from raw.bookings r
				left join ods.ods_booking o
					on o.book_ref = r.book_ref
				where v_load_type = 'FULL'
					or o.book_ref is null
					or o.row_hash <> r.row_hash
			) r
			where r.book_ref is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.bookings',
				to_jsonb(r) - 'key_cnt',
				case
					when r.book_ref is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.book_ref is null then 'book_ref is NULL'
					when r.key_cnt > 1 then 'Duplicate book_ref'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.book_ref) as key_cnt
				from raw.bookings r
				left join ods.ods_booking o
					on o.book_ref = r.book_ref
				where v_load_type = 'FULL'
					or o.book_ref is null
					or o.row_hash <> r.row_hash
			) r
			where r.book_ref is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- билеты: raw.tickets -> stg.tickets
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа)
create or replace procedure stg.load_tickets(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.tickets', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.tickets r
			left join ods.ods_ticket o
				on o.ticket_no = r.ticket_no
			where v_load_type = 'FULL'
				or o.ticket_no is null
				or o.row_hash <> r.row_hash;

			truncate stg.tickets;

			-- корректные строки
			insert into stg.tickets (
				ticket_no,
				book_ref,
				passenger_id,
				passenger_name,
				outbound,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.ticket_no,
				r.book_ref,
				r.passenger_id,
				trim(r.passenger_name),
				r.outbound,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no) as key_cnt,
					case
						when v_load_type = 'FULL' or o.ticket_no is null then 'I'
						else 'U'
					end as change_type
				from raw.tickets r
				left join ods.ods_ticket o
					on o.ticket_no = r.ticket_no
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.tickets',
				to_jsonb(r) - 'key_cnt',
				case
					when r.ticket_no is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.ticket_no is null then 'ticket_no is NULL'
					when r.key_cnt > 1 then 'Duplicate ticket_no'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no) as key_cnt
				from raw.tickets r
				left join ods.ods_ticket o
					on o.ticket_no = r.ticket_no
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- перелёты: raw.segments -> stg.segments
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа),
--   DQ_STG_003 (price NULL или < 0), DQ_STG_004 (fare_conditions NULL или не из списка)
create or replace procedure stg.load_segments(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.segments', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.segments r
			left join ods.ods_segment o
				on o.ticket_no = r.ticket_no
				and o.flight_id = r.flight_id
			where v_load_type = 'FULL'
				or o.ticket_no is null
				or o.row_hash <> r.row_hash;

			truncate stg.segments;

			-- корректные строки
			insert into stg.segments (
				ticket_no,
				flight_id,
				fare_conditions,
				price,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.ticket_no,
				r.flight_id,
				r.fare_conditions,
				r.price,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no, r.flight_id) as key_cnt,
					case
						when v_load_type = 'FULL' or o.ticket_no is null then 'I'
						else 'U'
					end as change_type
				from raw.segments r
				left join ods.ods_segment o
					on o.ticket_no = r.ticket_no
					and o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is not null
				and r.flight_id is not null
				and r.key_cnt = 1
				and r.price >= 0
				and r.fare_conditions in ('Economy', 'Comfort', 'Business');

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.segments',
				to_jsonb(r) - 'key_cnt',
				case
					when r.ticket_no is null or r.flight_id is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
					when r.price is null or r.price < 0 then 'DQ_STG_003'
					else 'DQ_STG_004'
				end,
				case
					when r.ticket_no is null or r.flight_id is null then 'ticket_no or flight_id is NULL'
					when r.key_cnt > 1 then 'Duplicate ticket_no + flight_id'
					when r.price is null or r.price < 0 then 'price is NULL or negative'
					else 'Invalid fare_conditions'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no, r.flight_id) as key_cnt
				from raw.segments r
				left join ods.ods_segment o
					on o.ticket_no = r.ticket_no
					and o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is null
				or r.flight_id is null
				or r.key_cnt > 1
				or r.price is null
				or r.price < 0
				or r.fare_conditions is null
				or r.fare_conditions not in ('Economy', 'Comfort', 'Business');

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- посадочные талоны: raw.boarding_passes -> stg.boarding_passes
-- правила карантина: DQ_STG_001 (ключ NULL), DQ_STG_002 (дубль ключа)
create or replace procedure stg.load_boarding_passes(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_rejected int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'STG', 'stg.boarding_passes', v_load_type)
		returning step_id into v_step_id;

		begin

			-- размер пакета
			select count(*)
			into v_rows_read
			from raw.boarding_passes r
			left join ods.ods_boarding_pass o
				on o.ticket_no = r.ticket_no
				and o.flight_id = r.flight_id
			where v_load_type = 'FULL'
				or o.ticket_no is null
				or o.row_hash <> r.row_hash;

			truncate stg.boarding_passes;

			-- корректные строки
			insert into stg.boarding_passes (
				ticket_no,
				flight_id,
				seat_no,
				boarding_no,
				boarding_time,
				row_hash,
				change_type,
				run_id,
				step_id
			)
			select
				r.ticket_no,
				r.flight_id,
				r.seat_no,
				r.boarding_no,
				r.boarding_time,
				r.row_hash,
				r.change_type,
				p_run_id,
				v_step_id
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no, r.flight_id) as key_cnt,
					case
						when v_load_type = 'FULL' or o.ticket_no is null then 'I'
						else 'U'
					end as change_type
				from raw.boarding_passes r
				left join ods.ods_boarding_pass o
					on o.ticket_no = r.ticket_no
					and o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is not null
				and r.flight_id is not null
				and r.key_cnt = 1;

			get diagnostics v_rows_inserted = row_count;

			-- некорректные строки -> карантин
			insert into etl.etl_quarantine (
				run_id,
				step_id,
				source_table,
				row_data,
				rule_code,
				reject_reason
			)
			select
				p_run_id,
				v_step_id,
				'raw.boarding_passes',
				to_jsonb(r) - 'key_cnt',
				case
					when r.ticket_no is null or r.flight_id is null then 'DQ_STG_001'
					when r.key_cnt > 1 then 'DQ_STG_002'
				end,
				case
					when r.ticket_no is null or r.flight_id is null then 'ticket_no or flight_id is NULL'
					when r.key_cnt > 1 then 'Duplicate ticket_no + flight_id'
				end
			from (
				select
					r.*,
					count(*) over (partition by r.ticket_no, r.flight_id) as key_cnt
				from raw.boarding_passes r
				left join ods.ods_boarding_pass o
					on o.ticket_no = r.ticket_no
					and o.flight_id = r.flight_id
				where v_load_type = 'FULL'
					or o.ticket_no is null
					or o.row_hash <> r.row_hash
			) r
			where r.ticket_no is null
				or r.flight_id is null
				or r.key_cnt > 1;

			get diagnostics v_rows_rejected = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_rejected then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, rejected=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_rejected;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_rejected = v_rows_rejected
			where step_id = v_step_id;

		exception
			when others then
				get stacked diagnostics
					v_error_code = returned_sqlstate,
					v_error_message = message_text;

				update etl.etl_step_logs
				set
					ended_at = clock_timestamp(),
					status = 'FAILED',
					rows_read = coalesce(v_rows_read, 0),
					rows_inserted = 0,
					rows_rejected = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;
