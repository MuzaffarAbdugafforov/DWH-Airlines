-- RAW layer
-- ТЗ п.3: технически точная копия исходных данных (bookings.*);
-- допустимы служебные поля load_id, loaded_at, source_name, row_hash.
-- Без бизнес-фильтрации и исправления ошибок, поэтому:
--   * бизнес-колонки имеют те же типы, что и в источнике;
--   * нет PK / NOT NULL / FK на бизнес-колонках - дубли и NULL должны дойти до STG,
--     где они обрабатываются и уходят в etl.etl_quarantine (ТЗ п.3, п.7);
--   * NOT NULL только на служебных полях.
-- Служебные поля:
--   load_id     - run_id из etl.etl_runs (FK добавим после создания схемы etl)
--   loaded_at   - время загрузки строки
--   source_name - таблица-источник, например 'bookings.flights'
--   row_hash    - md5 бизнес-колонок, для поиска изменений (ТЗ п.6: сравнение ключей / хешей)



--drop table if exists raw.bookings;
--drop table if exists raw.tickets;
--drop table if exists raw.segments;
--drop table if exists raw.flights;
--drop table if exists raw.boarding_passes;
--drop table if exists raw.routes;
--drop table if exists raw.airports_data;
--drop table if exists raw.airplanes_data;
--drop table if exists raw.seats;

create table if not exists raw.bookings (
	book_ref char(6),
	book_date timestamptz,
	total_amount numeric(10, 2),
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);

create table if not exists raw.tickets (
	ticket_no text,
	book_ref char(6),
	passenger_id text,
	passenger_name text,
	outbound boolean,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.segments (
	ticket_no text,
	flight_id integer,
	fare_conditions text,
	price numeric(10, 2),
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.flights (
	flight_id integer,
	route_no text,
	status text,
	scheduled_departure timestamptz,
	scheduled_arrival timestamptz,
	actual_departure timestamptz,
	actual_arrival timestamptz,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.boarding_passes (
	ticket_no text,
	flight_id integer,
	seat_no text,
	boarding_no integer,
	boarding_time timestamptz,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.routes (
	route_no text,
	validity tstzrange,
	departure_airport char(3),
	arrival_airport char(3),
	airplane_code char(3),
	days_of_week integer[],
	scheduled_time time,
	duration interval,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.airports_data (
	airport_code char(3),
	airport_name jsonb,
	city jsonb,
	country jsonb,
	coordinates point,
	timezone text,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.airplanes_data (
	airplane_code char(3),
	model jsonb,
	range integer,
	speed integer,
	
	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);


create table if not exists raw.seats (
	airplane_code char(3),
	seat_no text,
	fare_conditions text,

	run_id integer not null,
	step_id integer not null,
	loaded_at timestamptz not null default clock_timestamp(),
	source_name varchar(100) not null,
	row_hash varchar(32) not null
);



-- =====================================================================
-- RAW load procedures
-- ТЗ п.6: в источнике нет признака обновления -> RAW всегда полный снимок
-- (truncate + insert), изменения ищутся дальше по ключам / row_hash.
-- Шаблон из etl_lab: step log -> загрузка -> сверка -> SUCCESS / FAILED.
-- =====================================================================

create or replace procedure raw.load_bookings(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.bookings', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.bookings;

			truncate raw.bookings;

			insert into raw.bookings (
				book_ref,
				book_date,
				total_amount,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				b.book_ref,
				b.book_date,
				b.total_amount,
				p_run_id,
				v_step_id,
				'bookings.bookings',
				-- row() различает NULL и пустую строку и позицию колонки;
				-- timestamptz в UTC, чтобы хеш не зависел от timezone сессии
				md5(row(
					b.book_ref,
					b.book_date at time zone 'UTC',
					b.total_amount
				)::text)
			from
				bookings.bookings b;

			get diagnostics v_rows_inserted = row_count;
			
--			raise exception 'Artifisial error call!'

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_tickets(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.tickets', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.tickets;

			truncate raw.tickets;

			insert into raw.tickets (
				ticket_no,
				book_ref,
				passenger_id,
				passenger_name,
				outbound,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				t.ticket_no,
				t.book_ref,
				t.passenger_id,
				t.passenger_name,
				t.outbound,
				p_run_id,
				v_step_id,
				'bookings.tickets',
				md5(row(
					t.ticket_no,
					t.book_ref,
					t.passenger_id,
					t.passenger_name,
					t.outbound
				)::text)
			from
				bookings.tickets t;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_segments(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.segments', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.segments;

			truncate raw.segments;

			insert into raw.segments (
				ticket_no,
				flight_id,
				fare_conditions,
				price,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				s.ticket_no,
				s.flight_id,
				s.fare_conditions,
				s.price,
				p_run_id,
				v_step_id,
				'bookings.segments',
				md5(row(
					s.ticket_no,
					s.flight_id,
					s.fare_conditions,
					s.price
				)::text)
			from
				bookings.segments s;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_flights(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.flights', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.flights;

			truncate raw.flights;

			insert into raw.flights (
				flight_id,
				route_no,
				status,
				scheduled_departure,
				scheduled_arrival,
				actual_departure,
				actual_arrival,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				f.flight_id,
				f.route_no,
				f.status,
				f.scheduled_departure,
				f.scheduled_arrival,
				f.actual_departure,
				f.actual_arrival,
				p_run_id,
				v_step_id,
				'bookings.flights',
				md5(row(
					f.flight_id,
					f.route_no,
					f.status,
					f.scheduled_departure at time zone 'UTC',
					f.scheduled_arrival at time zone 'UTC',
					f.actual_departure at time zone 'UTC',
					f.actual_arrival at time zone 'UTC'
				)::text)
			from
				bookings.flights f;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_boarding_passes(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.boarding_passes', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.boarding_passes;

			truncate raw.boarding_passes;

			insert into raw.boarding_passes (
				ticket_no,
				flight_id,
				seat_no,
				boarding_no,
				boarding_time,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				bp.ticket_no,
				bp.flight_id,
				bp.seat_no,
				bp.boarding_no,
				bp.boarding_time,
				p_run_id,
				v_step_id,
				'bookings.boarding_passes',
				md5(row(
					bp.ticket_no,
					bp.flight_id,
					bp.seat_no,
					bp.boarding_no,
					bp.boarding_time at time zone 'UTC'
				)::text)
			from
				bookings.boarding_passes bp;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_routes(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.routes', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.routes;

			truncate raw.routes;

			insert into raw.routes (
				route_no,
				validity,
				departure_airport,
				arrival_airport,
				airplane_code,
				days_of_week,
				scheduled_time,
				duration,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				r.route_no,
				r.validity,
				r.departure_airport,
				r.arrival_airport,
				r.airplane_code,
				r.days_of_week,
				r.scheduled_time,
				r.duration,
				p_run_id,
				v_step_id,
				'bookings.routes',
				-- tstzrange выводится в timezone сессии -> границы в UTC;
				-- interval выводится по IntervalStyle -> в секундах
				md5(row(
					r.route_no,
					lower(r.validity) at time zone 'UTC',
					upper(r.validity) at time zone 'UTC',
					lower_inc(r.validity),
					upper_inc(r.validity),
					r.departure_airport,
					r.arrival_airport,
					r.airplane_code,
					r.days_of_week,
					r.scheduled_time,
					extract(epoch from r.duration)
				)::text)
			from
				bookings.routes r;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_airports_data(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.airports_data', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.airports_data;

			truncate raw.airports_data;

			insert into raw.airports_data (
				airport_code,
				airport_name,
				city,
				country,
				coordinates,
				timezone,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				a.airport_code,
				a.airport_name,
				a.city,
				a.country,
				a.coordinates,
				a.timezone,
				p_run_id,
				v_step_id,
				'bookings.airports_data',
				md5(row(
					a.airport_code,
					a.airport_name,
					a.city,
					a.country,
					a.coordinates,
					a.timezone
				)::text)
			from
				bookings.airports_data a;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_airplanes_data(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.airplanes_data', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.airplanes_data;

			truncate raw.airplanes_data;

			insert into raw.airplanes_data (
				airplane_code,
				model,
				range,
				speed,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				ap.airplane_code,
				ap.model,
				ap.range,
				ap.speed,
				p_run_id,
				v_step_id,
				'bookings.airplanes_data',
				md5(row(
					ap.airplane_code,
					ap.model,
					ap.range,
					ap.speed
				)::text)
			from
				bookings.airplanes_data ap;

			get diagnostics v_rows_inserted = row_count;
			
--			raise exception 'Artifisial Error!';

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



create or replace procedure raw.load_seats(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'RAW', 'raw.seats', 'FULL')
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from bookings.seats;

			truncate raw.seats;

			insert into raw.seats (
				airplane_code,
				seat_no,
				fare_conditions,
				run_id,
				step_id,
				source_name,
				row_hash
			)
			select
				st.airplane_code,
				st.seat_no,
				st.fare_conditions,
				p_run_id,
				v_step_id,
				'bookings.seats',
				md5(row(
					st.airplane_code,
					st.seat_no,
					st.fare_conditions
				)::text)
			from
				bookings.seats st;

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted then
				raise exception
					'Data reconciliation failed: read=%, inserted=%',
					v_rows_read,
					v_rows_inserted;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;



-- =====================================================================
-- RAW DQ: сверка SOURCE <-> RAW (ТЗ п.7: сверка количества/сумм между слоями)
--   DQ_RAW_001  Row count SOURCE = RAW        - для всех 9 таблиц
--   DQ_RAW_005  Amount sum SOURCE = RAW       - bookings.total_amount, segments.price
-- p_table_name - имя таблицы без схемы ('bookings', 'segments', ...):
-- источник bookings.<table>, RAW raw.<table>.
-- step_id - этап загрузки этой RAW-таблицы в текущем запуске.
-- =====================================================================

create or replace procedure etl.dq_raw_count(p_run_id integer, p_table_name text)
language plpgsql
as $$
	declare
		v_source_count bigint;
		v_raw_count bigint;
	begin
		execute format('select count(*) from bookings.%I', p_table_name)
		into v_source_count;

		execute format('select count(*) from raw.%I', p_table_name)
		into v_raw_count;

		insert into etl.etl_dq_results (
			run_id,
			step_id,
			table_name,
			rule_code,
			rule_description,
			severity,
			rows_checked,
			violations_count,
			status
		)
		select
			p_run_id,
			(select max(sl.step_id)
			 from etl.etl_step_logs sl
			 where sl.run_id = p_run_id
			 	and sl.table_name = 'raw.' || p_table_name),
			'raw.' || p_table_name,
			'DQ_RAW_001',
			'Row count mismatch between SOURCE and RAW',
			'CRITICAL',
			v_source_count,
			abs(v_source_count - v_raw_count),
			case
				when v_source_count = v_raw_count then 'PASSED'
				else 'FAILED'
			end;
	end;
$$;



create or replace procedure etl.dq_raw_sum(p_run_id integer, p_table_name text, p_column_name text)
language plpgsql
as $$
	declare
		v_source_sum numeric;
		v_raw_sum numeric;
		v_raw_count bigint;
	begin
		execute format('select coalesce(sum(%I), 0) from bookings.%I', p_column_name, p_table_name)
		into v_source_sum;

		execute format('select coalesce(sum(%I), 0), count(*) from raw.%I', p_column_name, p_table_name)
		into v_raw_sum, v_raw_count;

		insert into etl.etl_dq_results (
			run_id,
			step_id,
			table_name,
			rule_code,
			rule_description,
			severity,
			rows_checked,
			violations_count,
			status
		)
		select
			p_run_id,
			(select max(sl.step_id)
			 from etl.etl_step_logs sl
			 where sl.run_id = p_run_id
			 	and sl.table_name = 'raw.' || p_table_name),
			'raw.' || p_table_name,
			'DQ_RAW_005',
			'Sum of ' || p_column_name || ' mismatch between SOURCE and RAW',
			'CRITICAL',
			v_raw_count,
			case
				when v_source_sum = v_raw_sum then 0
				else 1
			end,
			case
				when v_source_sum = v_raw_sum then 'PASSED'
				else 'FAILED'
			end;
	end;
$$;



create or replace procedure etl.check_raw(p_run_id integer)
language plpgsql
as $$
	begin
		call etl.dq_raw_count(p_run_id, 'bookings');
		call etl.dq_raw_count(p_run_id, 'tickets');
		call etl.dq_raw_count(p_run_id, 'segments');
		call etl.dq_raw_count(p_run_id, 'flights');
		call etl.dq_raw_count(p_run_id, 'boarding_passes');
		call etl.dq_raw_count(p_run_id, 'routes');
		call etl.dq_raw_count(p_run_id, 'airports_data');
		call etl.dq_raw_count(p_run_id, 'airplanes_data');
		call etl.dq_raw_count(p_run_id, 'seats');

		call etl.dq_raw_sum(p_run_id, 'bookings', 'total_amount');
		call etl.dq_raw_sum(p_run_id, 'segments', 'price');
	end;
$$;



-- старый ручной запуск, заменён на call etl.run_pipeline() (Airlines - Orchestration.sql)
/*
do $$
declare
        p_run_id int;
        v_failed_steps int;
begin
        insert into etl.etl_runs (load_type)
        values ('FULL')
        returning run_id into p_run_id;

        call raw.load_bookings(p_run_id);
        call raw.load_tickets(p_run_id);
        call raw.load_segments(p_run_id);
        call raw.load_flights(p_run_id);
        call raw.load_boarding_passes(p_run_id);
        call raw.load_routes(p_run_id);
        call raw.load_airports_data(p_run_id);
        call raw.load_airplanes_data(p_run_id);
        call raw.load_seats(p_run_id);

        call etl.check_raw(p_run_id);

        -- закрываем run: FAILED, если упал хотя бы один этап
        select count(*)
        into v_failed_steps
        from etl.etl_step_logs
        where run_id = p_run_id
                and status = 'FAILED';

        update etl.etl_runs
        set
                ended_at = clock_timestamp(),
                status = case when v_failed_steps = 0 then 'SUCCESS' else 'FAILED' end,
                error_message = case when v_failed_steps = 0 then null
                        else v_failed_steps || ' step(s) failed, see etl.etl_step_logs' end
        where run_id = p_run_id;

        raise notice 'run_id = %, failed steps = %', p_run_id, v_failed_steps;
end;
$$ language plpgsql;
*/


select * from raw.airplanes_data ad;
select * from etl.etl_dq_results edr;