-- ods layer
-- ТЗ п.3: интегрированные сущности на бизнес-ключах, актуальное операционное
--         состояние, связи и согласованные правила обновления.
-- ТЗ п.4: ods_booking, ods_ticket, ods_segment, ods_flight, ods_route,
--         ods_boarding_pass (+ необходимые справочники: ods_airport, ods_airplane, ods_seat).



-- порядок удаления обратный порядку создания (сначала дочерние таблицы)
--drop table if exists ods.ods_boarding_pass;
--drop table if exists ods.ods_segment;
--drop table if exists ods.ods_ticket;
--drop table if exists ods.ods_booking;
--drop table if exists ods.ods_flight;
--drop table if exists ods.ods_route;
--drop table if exists ods.ods_seat;
--drop table if exists ods.ods_airplane;
--drop table if exists ods.ods_airport;


-- =====================================================================
-- Справочники
-- =====================================================================

-- аэропорты (из bookings.airports_data)
create table if not exists ods.ods_airport (
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
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_airport primary key (airport_code)
);


-- самолёты (из bookings.airplanes_data)
create table if not exists ods.ods_airplane (
	airplane_code char(3) not null,
	model_en text not null,
	model_ru text not null,
	range integer not null,
	speed integer not null,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_airplane primary key (airplane_code)
);


-- места в самолёте (нужны для загрузки мест: число мест модели)
create table if not exists ods.ods_seat (
	airplane_code char(3) not null,
	seat_no text not null,
	fare_conditions text not null,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_seat primary key (airplane_code, seat_no),
	constraint fk_ods_seat_airplane
		foreign key (airplane_code) references ods.ods_airplane (airplane_code)
);


-- маршруты с периодом действия: validity [valid_from, valid_to)
-- valid_from включительно, valid_to НЕ включительно (как tstzrange в источнике).
-- Один route_no имеет несколько версий (по месяцам) -> ключ (route_no, valid_from).
create table if not exists ods.ods_route (
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
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_route primary key (route_no, valid_from),
	constraint fk_ods_route_departure_airport
		foreign key (departure_airport) references ods.ods_airport (airport_code),
	constraint fk_ods_route_arrival_airport
		foreign key (arrival_airport) references ods.ods_airport (airport_code),
	constraint fk_ods_route_airplane
		foreign key (airplane_code) references ods.ods_airplane (airplane_code)
);


-- =====================================================================
-- Операционные сущности
-- =====================================================================

-- рейсы
-- ВНИМАНИЕ: FK на ods_route сделать нельзя - у рейса есть только route_no,
-- а ключ маршрута (route_no, valid_from). Нужная версия маршрута ищется по
-- scheduled_departure внутри [valid_from, valid_to) -> проверяем через DQ (ТЗ п.7).
create table if not exists ods.ods_flight (
	flight_id integer not null,
	route_no text not null,
	status text not null,
	scheduled_departure timestamptz not null,
	scheduled_arrival timestamptz not null,
	actual_departure timestamptz,
	actual_arrival timestamptz,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_flight primary key (flight_id)
);


-- бронирования
create table if not exists ods.ods_booking (
	book_ref char(6) not null,
	book_date timestamptz not null,
	total_amount numeric(10, 2) not null,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_booking primary key (book_ref)
);


-- билеты
create table if not exists ods.ods_ticket (
	ticket_no text not null,
	book_ref char(6) not null,
	passenger_id text not null,
	passenger_name text not null,
	outbound boolean not null,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_ticket primary key (ticket_no),
	constraint fk_ods_ticket_booking
		foreign key (book_ref) references ods.ods_booking (book_ref)
);


-- перелёты в составе билета (одна строка = один сегмент билета)
create table if not exists ods.ods_segment (
	ticket_no text not null,
	flight_id integer not null,
	fare_conditions text not null,
	price numeric(10, 2) not null,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_segment primary key (ticket_no, flight_id),
	constraint fk_ods_segment_ticket
		foreign key (ticket_no) references ods.ods_ticket (ticket_no),
	constraint fk_ods_segment_flight
		foreign key (flight_id) references ods.ods_flight (flight_id)
);


-- посадочные талоны (один талон на один сегмент)
-- boarding_no / boarding_time NULL = талон выдан, посадки не было (30 360 строк в источнике)
create table if not exists ods.ods_boarding_pass (
	ticket_no text not null,
	flight_id integer not null,
	seat_no text not null,
	boarding_no integer,
	boarding_time timestamptz,

	row_hash varchar(32) not null,
	run_id integer not null,
	step_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_ods_boarding_pass primary key (ticket_no, flight_id),
	constraint fk_ods_boarding_pass_segment
		foreign key (ticket_no, flight_id) references ods.ods_segment (ticket_no, flight_id)
);


-- =====================================================================
-- Индексы на FK-колонках дочерних таблиц
-- (PK индексируется автоматически, FK - нет). Без них проверка FK при
-- изменении родителя сканирует всю дочернюю таблицу (миллионы строк).
-- segment.ticket_no и boarding_pass(ticket_no, flight_id) уже покрыты своими PK.
-- =====================================================================
create index if not exists ix_ods_ticket_book_ref on ods.ods_ticket (book_ref);
create index if not exists ix_ods_segment_flight_id on ods.ods_segment (flight_id);
create index if not exists ix_ods_flight_route_no on ods.ods_flight (route_no, scheduled_departure);



-- =====================================================================
-- ODS загрузчики
-- =====================================================================
-- ТЗ п.3: актуальное операционное состояние на бизнес-ключах, связи,
--         согласованные правила обновления.
-- ТЗ п.6: повторный запуск пакета не создаёт дубликатов в ODS (идемпотентность).
--
-- Правило обновления - по change_type из STG:
--   'U' -> update существующей строки ODS по бизнес-ключу
--   'I' -> insert новой строки
-- Почему не delete + insert (как в Inmon ODS): в ODS есть FK. Удалить
-- бронирование 'U', у которого в ODS уже есть билеты, нельзя (FK violation),
-- а ON DELETE CASCADE удалил бы билеты, которых нет в STG -> потеря данных.
--
-- FULL: перед загрузчиками ods.clear_ods очищает все 9 таблиц одним truncate,
--       в STG все строки 'I' -> загрузчики только вставляют.
-- Порядок загрузчиков - сначала родители (из-за FK):
--   airport, airplane -> seat, route -> flight, booking -> ticket -> segment -> boarding_pass
-- Сверка в каждом загрузчике: read (строк в STG) = inserted + updated.
-- Карантина в ODS нет: плохие строки отсеяны в STG. Ошибка FK (строка-сирота)
-- -> step FAILED -> исправление и перезапуск (решение "вариант 1").


-- FULL: очистка ODS. Один truncate со списком всех таблиц: PostgreSQL разрешает
-- truncate родителя, только если все ссылающиеся на него таблицы в той же команде.
-- При INCREMENTAL ничего не делает.
create or replace procedure ods.clear_ods(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		if v_load_type <> 'FULL' then
			return;
		end if;

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'ODS', 'ods.* (truncate)', v_load_type)
		returning step_id into v_step_id;

		begin

			truncate
				ods.ods_boarding_pass,
				ods.ods_segment,
				ods.ods_ticket,
				ods.ods_booking,
				ods.ods_flight,
				ods.ods_route,
				ods.ods_seat,
				ods.ods_airplane,
				ods.ods_airport;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS'
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
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- аэропорты: stg.airports -> ods.ods_airport
create or replace procedure ods.load_airport(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_airport', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.airports;

			-- изменённые строки
			update ods.ods_airport o
			set
				airport_name_en = s.airport_name_en,
				airport_name_ru = s.airport_name_ru,
				city_en = s.city_en,
				city_ru = s.city_ru,
				country_en = s.country_en,
				country_ru = s.country_ru,
				longitude = s.longitude,
				latitude = s.latitude,
				timezone = s.timezone,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.airports s
			where s.airport_code = o.airport_code
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_airport (
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
				run_id,
				step_id
			)
			select
				s.airport_code,
				s.airport_name_en,
				s.airport_name_ru,
				s.city_en,
				s.city_ru,
				s.country_en,
				s.country_ru,
				s.longitude,
				s.latitude,
				s.timezone,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.airports s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- самолёты: stg.airplanes -> ods.ods_airplane
create or replace procedure ods.load_airplane(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_airplane', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.airplanes;

			-- изменённые строки
			update ods.ods_airplane o
			set
				model_en = s.model_en,
				model_ru = s.model_ru,
				range = s.range,
				speed = s.speed,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.airplanes s
			where s.airplane_code = o.airplane_code
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_airplane (
				airplane_code,
				model_en,
				model_ru,
				range,
				speed,
				row_hash,
				run_id,
				step_id
			)
			select
				s.airplane_code,
				s.model_en,
				s.model_ru,
				s.range,
				s.speed,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.airplanes s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- места: stg.seats -> ods.ods_seat
create or replace procedure ods.load_seat(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_seat', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.seats;

			-- изменённые строки
			update ods.ods_seat o
			set
				fare_conditions = s.fare_conditions,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.seats s
			where s.airplane_code = o.airplane_code
				and s.seat_no = o.seat_no
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_seat (
				airplane_code,
				seat_no,
				fare_conditions,
				row_hash,
				run_id,
				step_id
			)
			select
				s.airplane_code,
				s.seat_no,
				s.fare_conditions,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.seats s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- маршруты: stg.routes -> ods.ods_route (ключ route_no + valid_from)
create or replace procedure ods.load_route(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_route', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.routes;

			-- изменённые строки
			update ods.ods_route o
			set
				valid_to = s.valid_to,
				departure_airport = s.departure_airport,
				arrival_airport = s.arrival_airport,
				airplane_code = s.airplane_code,
				days_of_week = s.days_of_week,
				scheduled_time = s.scheduled_time,
				duration = s.duration,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.routes s
			where s.route_no = o.route_no
				and s.valid_from = o.valid_from
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_route (
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
				run_id,
				step_id
			)
			select
				s.route_no,
				s.valid_from,
				s.valid_to,
				s.departure_airport,
				s.arrival_airport,
				s.airplane_code,
				s.days_of_week,
				s.scheduled_time,
				s.duration,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.routes s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- рейсы: stg.flights -> ods.ods_flight
create or replace procedure ods.load_flight(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_flight', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.flights;

			-- изменённые строки
			update ods.ods_flight o
			set
				route_no = s.route_no,
				status = s.status,
				scheduled_departure = s.scheduled_departure,
				scheduled_arrival = s.scheduled_arrival,
				actual_departure = s.actual_departure,
				actual_arrival = s.actual_arrival,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.flights s
			where s.flight_id = o.flight_id
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_flight (
				flight_id,
				route_no,
				status,
				scheduled_departure,
				scheduled_arrival,
				actual_departure,
				actual_arrival,
				row_hash,
				run_id,
				step_id
			)
			select
				s.flight_id,
				s.route_no,
				s.status,
				s.scheduled_departure,
				s.scheduled_arrival,
				s.actual_departure,
				s.actual_arrival,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.flights s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- бронирования: stg.bookings -> ods.ods_booking
create or replace procedure ods.load_booking(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_booking', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.bookings;

			-- изменённые строки
			update ods.ods_booking o
			set
				book_date = s.book_date,
				total_amount = s.total_amount,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.bookings s
			where s.book_ref = o.book_ref
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_booking (
				book_ref,
				book_date,
				total_amount,
				row_hash,
				run_id,
				step_id
			)
			select
				s.book_ref,
				s.book_date,
				s.total_amount,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.bookings s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- билеты: stg.tickets -> ods.ods_ticket
create or replace procedure ods.load_ticket(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_ticket', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.tickets;

			-- изменённые строки
			update ods.ods_ticket o
			set
				book_ref = s.book_ref,
				passenger_id = s.passenger_id,
				passenger_name = s.passenger_name,
				outbound = s.outbound,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.tickets s
			where s.ticket_no = o.ticket_no
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_ticket (
				ticket_no,
				book_ref,
				passenger_id,
				passenger_name,
				outbound,
				row_hash,
				run_id,
				step_id
			)
			select
				s.ticket_no,
				s.book_ref,
				s.passenger_id,
				s.passenger_name,
				s.outbound,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.tickets s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- перелёты: stg.segments -> ods.ods_segment
create or replace procedure ods.load_segment(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_segment', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.segments;

			-- изменённые строки
			update ods.ods_segment o
			set
				fare_conditions = s.fare_conditions,
				price = s.price,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.segments s
			where s.ticket_no = o.ticket_no
				and s.flight_id = o.flight_id
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_segment (
				ticket_no,
				flight_id,
				fare_conditions,
				price,
				row_hash,
				run_id,
				step_id
			)
			select
				s.ticket_no,
				s.flight_id,
				s.fare_conditions,
				s.price,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.segments s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- посадочные талоны: stg.boarding_passes -> ods.ods_boarding_pass
create or replace procedure ods.load_boarding_pass(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;

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
		values (p_run_id, 'ODS', 'ods.ods_boarding_pass', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from stg.boarding_passes;

			-- изменённые строки
			update ods.ods_boarding_pass o
			set
				seat_no = s.seat_no,
				boarding_no = s.boarding_no,
				boarding_time = s.boarding_time,
				row_hash = s.row_hash,
				run_id = p_run_id,
				step_id = v_step_id,
				updated_at = clock_timestamp()
			from stg.boarding_passes s
			where s.ticket_no = o.ticket_no
				and s.flight_id = o.flight_id
				and s.change_type = 'U';

			get diagnostics v_rows_updated = row_count;

			-- новые строки
			insert into ods.ods_boarding_pass (
				ticket_no,
				flight_id,
				seat_no,
				boarding_no,
				boarding_time,
				row_hash,
				run_id,
				step_id
			)
			select
				s.ticket_no,
				s.flight_id,
				s.seat_no,
				s.boarding_no,
				s.boarding_time,
				s.row_hash,
				p_run_id,
				v_step_id
			from stg.boarding_passes s
			where s.change_type = 'I';

			get diagnostics v_rows_inserted = row_count;

			if v_rows_read <> v_rows_inserted + v_rows_updated then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, updated=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_updated;
			end if;

			update etl.etl_step_logs
			set
				ended_at = clock_timestamp(),
				status = 'SUCCESS',
				rows_read = v_rows_read,
				rows_inserted = v_rows_inserted,
				rows_updated = v_rows_updated
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
					rows_updated = 0,
					error_message = v_error_code || ': ' || v_error_message
				where step_id = v_step_id;
		end;
	end;
$$;


-- =====================================================================
-- ODS DQ: etl.check_ods
-- ТЗ п.7, специальные проверки домена:
--   DQ_ODS_001  рейс присоединяется ровно к одной версии маршрута:
--               route_no совпадает и scheduled_departure >= valid_from and < valid_to
--               (не between: соседние версии делят границу, рейс ровно на границе
--               попал бы в две версии -> двойной учёт). 0 версий или > 1 - нарушение.
--               FK так сделать нельзя: у рейса нет valid_from, только момент внутри периода.
--   DQ_ODS_002  посадки (boarding_time is not null) <= число мест самолёта
--               из версии маршрута, действующей на момент вылета.
--               Рейсы без версии маршрута сюда не попадают - их ловит DQ_ODS_001.
-- Проверяем всё ODS (актуальное состояние), а не только пакет.
-- step_id - этап загрузки проверяемой ODS-таблицы в текущем запуске.
-- Segment -> flight здесь не проверяем: это гарантирует FK fk_ods_segment_flight.
-- =====================================================================

create or replace procedure etl.check_ods(p_run_id integer)
language plpgsql
as $$
	begin

		-- DQ_ODS_001: рейс -> версия маршрута по интервалу validity
		insert into etl.etl_dq_results (
			run_id,
			step_id,
			table_name,
			rule_code,
			rule_description,
			severity,
			rows_checked,
			violations_count,
			sample_keys,
			status
		)
		select
			p_run_id,
			(select max(sl.step_id)
			 from etl.etl_step_logs sl
			 where sl.run_id = p_run_id
			 	and sl.table_name = 'ods.ods_flight'),
			'ods.ods_flight',
			'DQ_ODS_001',
			'Flight must match exactly one route version (scheduled_departure in [valid_from, valid_to))',
			'CRITICAL',
			count(*),
			count(*) filter (where m.route_versions <> 1),
			coalesce(to_jsonb((array_agg(m.flight_id order by m.flight_id) filter (where m.route_versions <> 1))[1:10]), '[]'),
			case
				when count(*) filter (where m.route_versions <> 1) = 0 then 'PASSED'
				else 'FAILED'
			end
		from (
			select
				f.flight_id,
				count(r.route_no) as route_versions
			from ods.ods_flight f
			left join ods.ods_route r
				on r.route_no = f.route_no
				and f.scheduled_departure >= r.valid_from
				and f.scheduled_departure < r.valid_to
			group by f.flight_id
		) m;


		-- DQ_ODS_002: посадки <= вместимость самолёта рейса
		insert into etl.etl_dq_results (
			run_id,
			step_id,
			table_name,
			rule_code,
			rule_description,
			severity,
			rows_checked,
			violations_count,
			sample_keys,
			status
		)
		select
			p_run_id,
			(select max(sl.step_id)
			 from etl.etl_step_logs sl
			 where sl.run_id = p_run_id
			 	and sl.table_name = 'ods.ods_boarding_pass'),
			'ods.ods_boarding_pass',
			'DQ_ODS_002',
			'Boardings per flight must not exceed airplane seat capacity',
			'ERROR',
			count(*),
			count(*) filter (where c.boardings > c.capacity),
			coalesce(to_jsonb((array_agg(c.flight_id order by c.flight_id) filter (where c.boardings > c.capacity))[1:10]), '[]'),
			case	
				when count(*) filter (where c.boardings > c.capacity) = 0 then 'PASSED'
				else 'FAILED'
			
		from (
			select
				b.flight_id,
				b.boardings,
				coalesce(s.seats, 0) as capacity
			from (
				-- фактические посадки по рейсу
				select
					bp.flight_id,
					count(*) as boardings
				from ods.ods_boarding_pass bp
				where bp.boarding_time is not null
				group by bp.flight_id
			) b
			join ods.ods_flight f
				on f.flight_id = b.flight_id
			join ods.ods_route r
				on r.route_no = f.route_no
				and f.scheduled_departure >= r.valid_from
				and f.scheduled_departure < r.valid_to
			left join (
				-- число мест по модели самолёта
				select
					st.airplane_code,
					count(*) as seats
				from ods.ods_seat st
				group by st.airplane_code
			) s
				on s.airplane_code = r.airplane_code
		) c;

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

        
        call stg.load_bookings(p_run_id);
        call stg.load_tickets(p_run_id);
        call stg.load_segments(p_run_id);
        call stg.load_flights(p_run_id);
        call stg.load_boarding_passes(p_run_id);
        call stg.load_routes(p_run_id);
        call stg.load_airports(p_run_id);
        call stg.load_airplanes(p_run_id);
        call stg.load_seats(p_run_id);
        
        call etl.check_stg(p_run_id);
        
		call ods.clear_ods(p_run_id);          -- only acts on FULL
		
		call ods.load_airport(p_run_id);
		call ods.load_airplane(p_run_id);
		call ods.load_seat(p_run_id);          -- after airplane
		call ods.load_route(p_run_id);         -- after airport + airplane
		call ods.load_flight(p_run_id);        -- no FK to route; after route anyway, for DQ_ODS_001
		call ods.load_booking(p_run_id);
		call ods.load_ticket(p_run_id);        -- after booking
		call ods.load_segment(p_run_id);       -- after ticket + flight
		call ods.load_boarding_pass(p_run_id); -- after segment
        
        call etl.check_ods(p_run_id);
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


delete from etl.etl_runs;

select * from etl.etl_runs er;
select * from etl.etl_step_logs esl;
select * from etl.etl_dq_results edr;
select * from etl.etl_quarantine eq;
