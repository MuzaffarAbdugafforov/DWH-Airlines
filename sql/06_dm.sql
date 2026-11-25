-- DM tables
-- ТЗ §4: две тематические витрины dm_sales_routes, dm_flight_performance; читаются Superset (ТЗ §8).
-- Источник = только DDS (fact_ticket_segment, fact_flight + измерения).
-- Правило обновления: полный пересчёт при каждом запуске (truncate + insert aggregate), как report.*_calc()
-- в DWHKimball. Повторный запуск даёт тот же результат → идемпотентно (ТЗ §6, T2).
-- Все даты в UTC (как в DDS).


-- dm_sales_routes
-- Grain: дата бронирования × маршрут (route_no) × класс обслуживания (fare_conditions).
-- Ключ: (book_date, route_no, fare_conditions). Аэропорты — атрибуты маршрута (route_no → пара аэропортов не меняется).
-- KPI (ТЗ §5):
--   revenue            = SUM(segments.price) по дате бронирования (bookings.total_amount не используется)
--   tickets_cnt        = COUNT(DISTINCT ticket_no) в строке. НЕ аддитивен: билет с несколькими сегментами
--                        попадает в несколько маршрутов → в Superset итог по билетам не суммировать по маршрутам
--   segments_cnt       = количество перелётов (ticket_no, flight_id)
--   avg_segment_price  = revenue / segments_cnt (в Superset считать SUM(revenue) / SUM(segments_cnt))
create table dm.dm_sales_routes (
	book_date date not null,
	route_no text not null,
	departure_airport char(3) not null,
	departure_city text not null,
	arrival_airport char(3) not null,
	arrival_city text not null,
	fare_conditions text not null,
	revenue numeric(14, 2) not null,
	tickets_cnt int not null,
	segments_cnt int not null,
	avg_segment_price numeric(10, 2) not null,
	run_id int not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_dm_sales_routes primary key (book_date, route_no, fare_conditions)
);


-- dm_flight_performance
-- Grain: дата рейса (scheduled_departure, UTC) × маршрут (route_no) × статус рейса.
-- Ключ: (flight_date, route_no, status). status в grain — для фильтра по статусу на дашборде (ТЗ §8).
-- KPI (ТЗ §5):
--   flights_cnt   = все рейсы
--   departed_cnt  = выполненные рейсы с известным фактическим вылетом (actual_departure is not null);
--                   будущие рейсы (Scheduled, On Time, Delayed, Boarding, Cancelled) сюда не входят
--   delayed_cnt   = выполненные рейсы с actual_departure > scheduled_departure + 15 минут
--   delay_share   = delayed_cnt / departed_cnt
--   boardings_cnt = подтверждённые посадки (boarding_time is not null) выполненных рейсов
--   seats_cnt     = мест в самолёте выполненных рейсов
--   load_factor   = boardings_cnt / seats_cnt
--   Условие применимости загрузки: рейс выполнен (actual_departure is not null) и известно число мест (seats_total > 0).
--   Посадки рейсов в статусе Boarding (ещё не вылетели) в загрузку не входят.
--   В Superset доли считать как SUM(числитель) / SUM(знаменатель), а не AVG(delay_share / load_factor).
create table dm.dm_flight_performance (
	flight_date date not null,
	route_no text not null,
	departure_airport char(3) not null,
	departure_city text not null,
	arrival_airport char(3) not null,
	arrival_city text not null,
	status text not null,
	flights_cnt int not null,
	departed_cnt int not null,
	delayed_cnt int not null,
	delay_share numeric(5, 4),
	boardings_cnt int not null,
	seats_cnt int not null,
	load_factor numeric(5, 4),
	run_id int not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_dm_flight_performance primary key (flight_date, route_no, status)
);


-- DM loaders
-- dm.load_<mart>(p_run_id): step log (stage DM), truncate, insert агрегата из DDS.
-- rows_read = строк факта, rows_inserted = строк витрины.
-- Сверка: сумма счётчика витрины (segments_cnt / flights_cnt) = rows_read — ни одна строка факта
-- не потеряна и не задублирована JOIN-ом с измерениями.


-- dm_sales_routes: dds.fact_ticket_segment + dim_date (book_date) + dim_route_scd2 (route_no) + dim_airport
create or replace procedure dm.load_sales_routes(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_segments_cnt int;

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
		values (p_run_id, 'DM', 'dm.dm_sales_routes', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from dds.fact_ticket_segment;

			truncate dm.dm_sales_routes;

			insert into dm.dm_sales_routes (
				book_date,
				route_no,
				departure_airport,
				departure_city,
				arrival_airport,
				arrival_city,
				fare_conditions,
				revenue,
				tickets_cnt,
				segments_cnt,
				avg_segment_price,
				run_id
			)
			select
				dd.date_actual,
				r.route_no,
				dep.airport_code,
				dep.city_en,
				arr.airport_code,
				arr.city_en,
				fs.fare_conditions,
				sum(fs.price),
				count(distinct fs.ticket_no),
				count(*),
				round(sum(fs.price) / count(*), 2),
				p_run_id
			from dds.fact_ticket_segment fs
			join dds.dim_date dd
				on dd.date_sk = fs.book_date_sk
			join dds.dim_route_scd2 r
				on r.route_sk = fs.route_sk
			join dds.dim_airport dep
				on dep.airport_sk = fs.departure_airport_sk
			join dds.dim_airport arr
				on arr.airport_sk = fs.arrival_airport_sk
			group by
				dd.date_actual,
				r.route_no,
				dep.airport_code,
				dep.city_en,
				arr.airport_code,
				arr.city_en,
				fs.fare_conditions;

			get diagnostics v_rows_inserted = row_count;

			select coalesce(sum(segments_cnt), 0)
			into v_segments_cnt
			from dm.dm_sales_routes;

			if v_rows_read <> v_segments_cnt then
				raise exception
					'Data reconciliation failed: fact rows=%, mart segments_cnt=%',
					v_rows_read,
					v_segments_cnt;
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


-- dm_flight_performance: dds.fact_flight + dim_date (flight_date) + dim_airport
create or replace procedure dm.load_flight_performance(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_flights_cnt int;

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
		values (p_run_id, 'DM', 'dm.dm_flight_performance', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from dds.fact_flight;

			truncate dm.dm_flight_performance;

			insert into dm.dm_flight_performance (
				flight_date,
				route_no,
				departure_airport,
				departure_city,
				arrival_airport,
				arrival_city,
				status,
				flights_cnt,
				departed_cnt,
				delayed_cnt,
				delay_share,
				boardings_cnt,
				seats_cnt,
				load_factor,
				run_id
			)
			select
				x.flight_date,
				x.route_no,
				x.departure_airport,
				x.departure_city,
				x.arrival_airport,
				x.arrival_city,
				x.status,
				x.flights_cnt,
				x.departed_cnt,
				x.delayed_cnt,
				round(x.delayed_cnt::numeric / nullif(x.departed_cnt, 0), 4),
				x.boardings_cnt,
				x.seats_cnt,
				round(x.boardings_cnt::numeric / nullif(x.seats_cnt, 0), 4),
				p_run_id
			from (
				select
					dd.date_actual as flight_date,
					ff.route_no,
					dep.airport_code as departure_airport,
					dep.city_en as departure_city,
					arr.airport_code as arrival_airport,
					arr.city_en as arrival_city,
					ff.status,
					count(*) as flights_cnt,
					count(*) filter (where ff.is_departed) as departed_cnt,
					count(*) filter (where ff.is_departed and ff.is_delayed) as delayed_cnt,
					coalesce(sum(ff.boardings) filter (where ff.is_departed and ff.seats_total > 0), 0) as boardings_cnt,
					coalesce(sum(ff.seats_total) filter (where ff.is_departed and ff.seats_total > 0), 0) as seats_cnt
				from dds.fact_flight ff
				join dds.dim_date dd
					on dd.date_sk = ff.scheduled_departure_date_sk
				join dds.dim_airport dep
					on dep.airport_sk = ff.departure_airport_sk
				join dds.dim_airport arr
					on arr.airport_sk = ff.arrival_airport_sk
				group by
					dd.date_actual,
					ff.route_no,
					dep.airport_code,
					dep.city_en,
					arr.airport_code,
					arr.city_en,
					ff.status
			) x;

			get diagnostics v_rows_inserted = row_count;

			select coalesce(sum(flights_cnt), 0)
			into v_flights_cnt
			from dm.dm_flight_performance;

			if v_rows_read <> v_flights_cnt then
				raise exception
					'Data reconciliation failed: fact rows=%, mart flights_cnt=%',
					v_rows_read,
					v_flights_cnt;
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
