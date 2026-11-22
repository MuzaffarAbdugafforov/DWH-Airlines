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


