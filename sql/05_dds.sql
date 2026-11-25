-- dds tables

-- =====================================================================
-- DDS: детальные факты и измерения (Kimball, звезда)
-- ТЗ п.3: детальные факты и измерения с документированной гранулярностью;
--         минимум одно измерение с историчностью SCD Type 2.
-- ТЗ п.4: fact_ticket_segment (одна строка = один сегмент билета),
--         fact_flight (одна строка = один рейс);
--         dim_route_scd2, dim_airport, dim_airplane, dim_date.
-- ТЗ п.4: для каждой таблицы - grain, бизнес-ключи, ограничения, источники,
--         правила обновления (в комментарии над таблицей).
-- ТЗ п.6: SCD2 - surrogate key, valid_from, valid_to, is_current.
--
-- Источник DDS - ODS (полное актуальное состояние со связями), не STG
-- (в STG только текущий пакет). INCREMENTAL: строки ODS с run_id = текущий запуск.
-- Суррогатные ключи (_sk) - у измерений (как <x>_pk serial в DWHKimball).
-- Факты: PK на бизнес-ключе (повторная загрузка не создаёт дублей, ТЗ п.6),
--        ссылки на измерения - по _sk (FK).
-- Технические колонки: run_id (запуск последнего изменения), updated_at.
-- =====================================================================


-- порядок удаления: сначала факты, потом измерения
--drop table if exists dds.fact_ticket_segment;
--drop table if exists dds.fact_flight;
--drop table if exists dds.dim_route_scd2;
--drop table if exists dds.dim_airplane;
--drop table if exists dds.dim_airport;
--drop table if exists dds.dim_date;


-- =====================================================================
-- Измерения
-- =====================================================================

-- dim_date
-- grain: один календарный день
-- ключ: date_sk = yyyymmdd (как core.dim_date в DWHKimball), бизнес-ключ date_actual
-- атрибуты: только нужные витринам и Superset (день недели, неделя, месяц,
--   квартал, год, выходной); остальное при необходимости считается из date_actual
-- источник: генерируется процедурой (диапазон дат бронирований и рейсов)
-- обновление: заполняется один раз, при необходимости дополняется новыми днями
create table if not exists dds.dim_date (
	date_sk integer not null,
	date_actual date not null,
	day_of_week integer not null,		-- ISO: 1 = понедельник ... 7 = воскресенье
	day_name varchar(9) not null,
	week_of_year integer not null,		-- ISO-неделя
	month_actual integer not null,
	month_name varchar(9) not null,
	quarter_actual integer not null,
	year_actual integer not null,
	weekend_indr boolean not null,

	constraint pk_dim_date primary key (date_sk),
	constraint uq_dim_date_date_actual unique (date_actual)
);


-- dim_airport
-- grain: один аэропорт
-- ключи: airport_sk (суррогатный), airport_code (бизнес-ключ, unique)
-- источник: ods.ods_airport
-- обновление: SCD1 - новые вставляются, изменённые перезаписываются
create table if not exists dds.dim_airport (
	airport_sk serial not null,
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

	run_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_dim_airport primary key (airport_sk),
	constraint uq_dim_airport_code unique (airport_code)
);


-- dim_airplane
-- grain: одна модель самолёта
-- ключи: airplane_sk (суррогатный), airplane_code (бизнес-ключ, unique)
-- источник: ods.ods_airplane + ods.ods_seat (count(*) мест -> seats_total)
-- seats_total - вместимость для коэффициента загрузки (ТЗ п.5)
-- обновление: SCD1; пересчёт, если изменился самолёт или его места
create table if not exists dds.dim_airplane (
	airplane_sk serial not null,
	airplane_code char(3) not null,
	model_en text not null,
	model_ru text not null,
	range integer not null,
	speed integer not null,
	seats_total integer not null,

	run_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_dim_airplane primary key (airplane_sk),
	constraint uq_dim_airplane_code unique (airplane_code),
	constraint ck_dim_airplane_seats check (seats_total >= 0)
);


-- dim_route_scd2
-- grain: одна версия атрибутов одного периода маршрута
-- ключи: route_sk (суррогатный);
--        бизнес-ключ периода маршрута: route_no + period_from
-- Два вида времени:
--   period_from / period_to - период действия маршрута из источника (validity),
--       [period_from, period_to); по нему рейс находит свой маршрут
--       (scheduled_departure >= period_from and < period_to)
--   valid_from / valid_to / is_current - SCD2: когда DWH видел эти атрибуты
--       первая версия: valid_from = '1900-01-01', открытая: valid_to = '9999-01-01'
--       (как effective_date_from / effective_date_to в DWHKimball)
-- источник: ods.ods_route
-- обновление SCD2: изменились атрибуты -> старая версия закрывается
--   (valid_to = время загрузки, is_current = false), вставляется новая (is_current = true)
-- ограничения: одна текущая версия на route_no + period_from (уникальный частичный индекс);
--   отсутствие пересечений valid_from/valid_to - DQ-проверка DDS (ТЗ п.6)
create table if not exists dds.dim_route_scd2 (
	route_sk serial not null,
	route_no text not null,
	period_from timestamptz not null,
	period_to timestamptz not null,
	departure_airport char(3) not null,
	arrival_airport char(3) not null,
	airplane_code char(3) not null,
	days_of_week integer[] not null,
	scheduled_time time not null,
	duration interval not null,

	row_hash varchar(32) not null,	-- хеш атрибутов из ODS: сравнение с текущей версией
	valid_from timestamptz not null,
	valid_to timestamptz not null,
	is_current boolean not null,

	run_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_dim_route_scd2 primary key (route_sk),
	constraint uq_dim_route_scd2_version unique (route_no, period_from, valid_from),
	constraint ck_dim_route_scd2_period check (period_to > period_from),
	constraint ck_dim_route_scd2_valid check (valid_to > valid_from)
);

-- не более одной текущей версии на период маршрута
create unique index if not exists uq_dim_route_scd2_current
	on dds.dim_route_scd2 (route_no, period_from)
	where is_current;


-- =====================================================================
-- Факты
-- =====================================================================

-- fact_flight
-- grain: один рейс
-- ключ: flight_id (бизнес-ключ = PK)
-- источник: ods.ods_flight + версия маршрута (dim_route_scd2, текущая, по периоду)
--           + посадки ods.ods_boarding_pass (boarding_time is not null)
-- меры / признаки (ТЗ п.5):
--   is_departed   - рейс выполнен: actual_departure известен (будущие рейсы = false)
--   delay_minutes - actual_departure - scheduled_departure в минутах (NULL, если не вылетел)
--   is_delayed    - actual_departure > scheduled_departure + 15 минут (NULL, если не вылетел)
--   boardings     - число подтверждённых посадок
--   seats_total   - вместимость самолёта рейса (на момент загрузки)
-- даты: scheduled_departure_date_sk - дата планового вылета (UTC)
-- обновление: новые вставляются, изменённые (статус, фактические времена,
--   посадки) перезаписываются; route_sk - версия маршрута на момент загрузки рейса
create table if not exists dds.fact_flight (
	flight_id integer not null,
	route_sk integer not null,
	departure_airport_sk integer not null,
	arrival_airport_sk integer not null,
	airplane_sk integer not null,
	scheduled_departure_date_sk integer not null,

	route_no text not null,
	status text not null,
	scheduled_departure timestamptz not null,
	scheduled_arrival timestamptz not null,
	actual_departure timestamptz,
	actual_arrival timestamptz,

	is_departed boolean not null,
	delay_minutes numeric(10, 2),
	is_delayed boolean,
	boardings integer not null,
	seats_total integer not null,

	run_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_fact_flight primary key (flight_id),
	constraint fk_fact_flight_route
		foreign key (route_sk) references dds.dim_route_scd2 (route_sk),
	constraint fk_fact_flight_departure_airport
		foreign key (departure_airport_sk) references dds.dim_airport (airport_sk),
	constraint fk_fact_flight_arrival_airport
		foreign key (arrival_airport_sk) references dds.dim_airport (airport_sk),
	constraint fk_fact_flight_airplane
		foreign key (airplane_sk) references dds.dim_airplane (airplane_sk),
	constraint fk_fact_flight_date
		foreign key (scheduled_departure_date_sk) references dds.dim_date (date_sk),
	constraint ck_fact_flight_boardings check (boardings >= 0)
);


-- fact_ticket_segment
-- grain: один сегмент билета (билет на один рейс)
-- ключ: ticket_no + flight_id (бизнес-ключ = PK; ТЗ: уникальность ticket_no + flight_id)
-- источник: ods.ods_segment + ods_ticket (book_ref) + ods_booking (book_date)
--           + ods_flight / dim_route_scd2 (маршрут, аэропорты, дата рейса)
--           + ods_boarding_pass (is_boarded)
-- меры: price - выручка сегмента; выручка = SUM(price) по дате бронирования (ТЗ п.5),
--       bookings.total_amount не используется (иначе двойной учёт)
-- даты: book_date_sk - дата бронирования (для выручки), flight_date_sk - дата рейса
-- обновление: новые вставляются, изменённые (price, класс, посадка) перезаписываются
create table if not exists dds.fact_ticket_segment (
	ticket_no text not null,
	flight_id integer not null,
	book_ref char(6) not null,
	book_date_sk integer not null,
	flight_date_sk integer not null,
	route_sk integer not null,
	departure_airport_sk integer not null,
	arrival_airport_sk integer not null,

	fare_conditions text not null,
	price numeric(10, 2) not null,
	is_boarded boolean not null,

	run_id integer not null,
	updated_at timestamptz not null default clock_timestamp(),

	constraint pk_fact_ticket_segment primary key (ticket_no, flight_id),
	constraint fk_fact_ticket_segment_book_date
		foreign key (book_date_sk) references dds.dim_date (date_sk),
	constraint fk_fact_ticket_segment_flight_date
		foreign key (flight_date_sk) references dds.dim_date (date_sk),
	constraint fk_fact_ticket_segment_route
		foreign key (route_sk) references dds.dim_route_scd2 (route_sk),
	constraint fk_fact_ticket_segment_departure_airport
		foreign key (departure_airport_sk) references dds.dim_airport (airport_sk),
	constraint fk_fact_ticket_segment_arrival_airport
		foreign key (arrival_airport_sk) references dds.dim_airport (airport_sk),
	constraint ck_fact_ticket_segment_price check (price >= 0)
);


-- =====================================================================
-- Индексы на FK-колонках фактов (для витрин DM и проверки FK)
-- fact_ticket_segment.ticket_no покрыт PK; flight_id - второй в PK, нужен отдельный.
-- =====================================================================
create index if not exists ix_fact_flight_route_sk on dds.fact_flight (route_sk);
create index if not exists ix_fact_flight_date_sk on dds.fact_flight (scheduled_departure_date_sk);
create index if not exists ix_fact_ticket_segment_flight_id on dds.fact_ticket_segment (flight_id);
create index if not exists ix_fact_ticket_segment_book_date_sk on dds.fact_ticket_segment (book_date_sk);
create index if not exists ix_fact_ticket_segment_route_sk on dds.fact_ticket_segment (route_sk);



-- =====================================================================
-- DDS загрузчики
-- =====================================================================
-- Источник - ODS. Порядок (измерения раньше фактов, fact_flight раньше
-- fact_ticket_segment - сегмент берёт маршрут и аэропорты из fact_flight):
--   dim_date -> dim_airport -> dim_airplane -> dim_route_scd2
--   -> fact_flight -> fact_ticket_segment
--
-- Какие строки ODS обрабатывать (водяной знак, как last_update в DWHKimball):
--   FULL        - все строки ODS
--   INCREMENTAL - строки ODS с updated_at > начала последнего УСПЕШНОГО шага
--                 этой же DDS-таблицы (etl.get_dds_watermark).
--   Почему не "run_id = текущий запуск": если DDS упал, а ODS успел загрузиться,
--   в следующем запуске STG/ODS уже ничего не изменят (ODS актуален), и строки
--   упавшего запуска никогда не дошли бы до DDS. Водяной знак от последнего
--   успешного шага подбирает их при перезапуске (ТЗ п.6).
--
-- FULL не очищает DDS: ODS после clear_ods перезагружен целиком, все строки
--   обрабатываются заново через update/insert -> дублей нет, а история SCD2
--   сохраняется (в ODS истории нет, truncate стёр бы её безвозвратно).
--
-- Обновление: SCD1-измерения и факты - update существующих по бизнес-ключу,
--   insert новых. dim_route_scd2 - SCD2 (закрыть старую версию, вставить новую).
-- Сверка: read (строк-кандидатов) = inserted + updated (+ unchanged для SCD2).
-- Даты (date_sk) - по UTC: (ts at time zone 'UTC')::date, не зависит от
--   часового пояса сессии.
-- analyze после загрузки: весь запуск - одна транзакция, autovacuum не видит
--   новых строк, и следующий загрузчик планирует запрос по старой статистике
--   (fact_flight "пустая" -> fact_ticket_segment шёл > 10 минут вместо ~2).
--   Временные таблицы autovacuum не анализирует никогда.
-- =====================================================================


-- водяной знак для DDS-таблицы
create or replace function etl.get_dds_watermark(p_run_id integer, p_table_name text)
returns timestamptz
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_watermark timestamptz;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		if v_load_type = 'FULL' then
			return '-infinity';
		end if;

		select max(sl.started_at)
		into v_watermark
		from etl.etl_step_logs sl
		where sl.table_name = p_table_name
			and sl.status = 'SUCCESS';

		return coalesce(v_watermark, '-infinity');
	end;
$$;


-- dim_date: дни от самой ранней до самой поздней даты бронирования / вылета (UTC)
-- новые дни вставляются, существующие не трогаются
create or replace procedure dds.load_dim_date(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_rows_read int;
		v_rows_inserted int;
		v_date_from date;
		v_date_to date;

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
		values (p_run_id, 'DDS', 'dds.dim_date', v_load_type)
		returning step_id into v_step_id;

		begin

			select
				least(b.date_from, f.date_from),
				greatest(b.date_to, f.date_to)
			into v_date_from, v_date_to
			from (
				select
					min(book_date at time zone 'UTC')::date as date_from,
					max(book_date at time zone 'UTC')::date as date_to
				from ods.ods_booking
			) b
			cross join (
				select
					min(scheduled_departure at time zone 'UTC')::date as date_from,
					max(scheduled_departure at time zone 'UTC')::date as date_to
				from ods.ods_flight
			) f;

			v_rows_read := v_date_to - v_date_from + 1;

			insert into dds.dim_date (
				date_sk,
				date_actual,
				day_of_week,
				day_name,
				week_of_year,
				month_actual,
				month_name,
				quarter_actual,
				year_actual,
				weekend_indr
			)
			select
				to_char(d, 'YYYYMMDD')::int,
				d,
				extract(isodow from d)::int,
				to_char(d, 'fmDay'),
				extract(week from d)::int,
				extract(month from d)::int,
				to_char(d, 'fmMonth'),
				extract(quarter from d)::int,
				extract(year from d)::int,
				extract(isodow from d) in (6, 7)
			from (
				select gs::date as d
				from generate_series(v_date_from::timestamp, v_date_to::timestamp, interval '1 day') gs
			) days
			where not exists (
				select 1
				from dds.dim_date dd
				where dd.date_actual = days.d
			);

			get diagnostics v_rows_inserted = row_count;

			analyze dds.dim_date;

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


-- dim_airport (SCD1): ods.ods_airport -> dds.dim_airport
create or replace procedure dds.load_dim_airport(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_watermark timestamptz;
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

		v_watermark := etl.get_dds_watermark(p_run_id, 'dds.dim_airport');

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'DDS', 'dds.dim_airport', v_load_type)
		returning step_id into v_step_id;

		begin

			select count(*)
			into v_rows_read
			from ods.ods_airport o
			where o.updated_at > v_watermark;

			-- изменённые
			update dds.dim_airport d
			set
				airport_name_en = o.airport_name_en,
				airport_name_ru = o.airport_name_ru,
				city_en = o.city_en,
				city_ru = o.city_ru,
				country_en = o.country_en,
				country_ru = o.country_ru,
				longitude = o.longitude,
				latitude = o.latitude,
				timezone = o.timezone,
				run_id = p_run_id,
				updated_at = clock_timestamp()
			from ods.ods_airport o
			where o.airport_code = d.airport_code
				and o.updated_at > v_watermark;

			get diagnostics v_rows_updated = row_count;

			-- новые
			insert into dds.dim_airport (
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
				run_id
			)
			select
				o.airport_code,
				o.airport_name_en,
				o.airport_name_ru,
				o.city_en,
				o.city_ru,
				o.country_en,
				o.country_ru,
				o.longitude,
				o.latitude,
				o.timezone,
				p_run_id
			from ods.ods_airport o
			where o.updated_at > v_watermark
				and not exists (
					select 1
					from dds.dim_airport d
					where d.airport_code = o.airport_code
				);

			get diagnostics v_rows_inserted = row_count;

			analyze dds.dim_airport;

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


-- dim_airplane (SCD1): ods.ods_airplane + число мест из ods.ods_seat
-- кандидаты: изменился сам самолёт ИЛИ хотя бы одно его место (меняется seats_total)
create or replace procedure dds.load_dim_airplane(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_watermark timestamptz;
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

		v_watermark := etl.get_dds_watermark(p_run_id, 'dds.dim_airplane');

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'DDS', 'dds.dim_airplane', v_load_type)
		returning step_id into v_step_id;

		begin

			drop table if exists tmp_dim_airplane;

			create temp table tmp_dim_airplane as
			select
				a.airplane_code,
				a.model_en,
				a.model_ru,
				a.range,
				a.speed,
				(select count(*)
				 from ods.ods_seat st
				 where st.airplane_code = a.airplane_code)::int as seats_total
			from ods.ods_airplane a
			where a.updated_at > v_watermark
				or exists (
					select 1
					from ods.ods_seat st
					where st.airplane_code = a.airplane_code
						and st.updated_at > v_watermark
				);

			select count(*)
			into v_rows_read
			from tmp_dim_airplane;

			-- изменённые
			update dds.dim_airplane d
			set
				model_en = t.model_en,
				model_ru = t.model_ru,
				range = t.range,
				speed = t.speed,
				seats_total = t.seats_total,
				run_id = p_run_id,
				updated_at = clock_timestamp()
			from tmp_dim_airplane t
			where t.airplane_code = d.airplane_code;

			get diagnostics v_rows_updated = row_count;

			-- новые
			insert into dds.dim_airplane (
				airplane_code,
				model_en,
				model_ru,
				range,
				speed,
				seats_total,
				run_id
			)
			select
				t.airplane_code,
				t.model_en,
				t.model_ru,
				t.range,
				t.speed,
				t.seats_total,
				p_run_id
			from tmp_dim_airplane t
			where not exists (
				select 1
				from dds.dim_airplane d
				where d.airplane_code = t.airplane_code
			);

			get diagnostics v_rows_inserted = row_count;

			analyze dds.dim_airplane;

			drop table tmp_dim_airplane;

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


-- dim_route_scd2 (SCD2): ods.ods_route -> dds.dim_route_scd2
-- Для каждого периода маршрута-кандидата (route_no + valid_from из ODS)
-- сравниваем row_hash с текущей версией (is_current):
--   версии нет          -> новая версия, valid_from = '1900-01-01' (первая)
--   hash совпадает      -> ничего (unchanged; так повторный FULL не плодит версии)
--   hash отличается     -> текущая закрывается: valid_to = v_load_ts, is_current = false;
--                          новая: valid_from = v_load_ts, valid_to = '9999-01-01'
-- Одно и то же v_load_ts для закрытия и открытия -> версии стыкуются без дыр
-- и без пересечений ([valid_from, valid_to)).
-- Сначала закрываем, потом вставляем: иначе частичный уникальный индекс
-- uq_dim_route_scd2_current увидит две текущие версии.
-- rows_updated = закрытые версии, rows_inserted = новые версии (новые + изменённые).
-- Сверка: read = inserted + unchanged.
create or replace procedure dds.load_dim_route_scd2(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_watermark timestamptz;
		v_load_ts timestamptz := clock_timestamp();
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;
		v_rows_unchanged int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		v_watermark := etl.get_dds_watermark(p_run_id, 'dds.dim_route_scd2');

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'DDS', 'dds.dim_route_scd2', v_load_type)
		returning step_id into v_step_id;

		begin

			drop table if exists tmp_dim_route;

			-- кандидаты + их текущая версия в DDS (если есть)
			create temp table tmp_dim_route as
			select
				o.route_no,
				o.valid_from as period_from,
				o.valid_to as period_to,
				o.departure_airport,
				o.arrival_airport,
				o.airplane_code,
				o.days_of_week,
				o.scheduled_time,
				o.duration,
				o.row_hash,
				d.route_sk as current_sk,
				d.row_hash as current_hash
			from ods.ods_route o
			left join dds.dim_route_scd2 d
				on d.route_no = o.route_no
				and d.period_from = o.valid_from
				and d.is_current
			where o.updated_at > v_watermark;

			select
				count(*),
				count(*) filter (where t.current_hash = t.row_hash)
			into v_rows_read, v_rows_unchanged
			from tmp_dim_route t;

			-- закрыть изменившиеся версии
			update dds.dim_route_scd2 d
			set
				valid_to = v_load_ts,
				is_current = false,
				run_id = p_run_id,
				updated_at = clock_timestamp()
			from tmp_dim_route t
			where t.current_sk = d.route_sk
				and t.current_hash <> t.row_hash;

			get diagnostics v_rows_updated = row_count;

			-- новые версии: новые периоды маршрутов + изменившиеся
			insert into dds.dim_route_scd2 (
				route_no,
				period_from,
				period_to,
				departure_airport,
				arrival_airport,
				airplane_code,
				days_of_week,
				scheduled_time,
				duration,
				row_hash,
				valid_from,
				valid_to,
				is_current,
				run_id
			)
			select
				t.route_no,
				t.period_from,
				t.period_to,
				t.departure_airport,
				t.arrival_airport,
				t.airplane_code,
				t.days_of_week,
				t.scheduled_time,
				t.duration,
				t.row_hash,
				case
					when t.current_sk is null then '1900-01-01 00:00:00+00'::timestamptz
					else v_load_ts
				end,
				'9999-01-01 00:00:00+00'::timestamptz,
				true,
				p_run_id
			from tmp_dim_route t
			where t.current_sk is null
				or t.current_hash <> t.row_hash;

			get diagnostics v_rows_inserted = row_count;

			analyze dds.dim_route_scd2;

			drop table tmp_dim_route;

			if v_rows_read <> v_rows_inserted + v_rows_unchanged then
				raise exception
					'Data reconciliation failed: read=%, inserted=%, unchanged=%',
					v_rows_read,
					v_rows_inserted,
					v_rows_unchanged;
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


-- fact_flight: ods.ods_flight + текущая версия маршрута + посадки
-- Рейс пересчитывается, если изменился:
--   сам рейс (статус, фактические времена)       - ods_flight.updated_at
--   любой его посадочный талон (boardings)        - ods_boarding_pass.updated_at
--   его маршрут (новая версия SCD2, другой самолёт) - dim_route_scd2.updated_at
--   его самолёт (seats_total)                     - dim_airplane.updated_at
-- Суррогатные ключи - поиском по бизнес-ключу в измерениях (left join).
-- Не нашёлся ключ -> понятная ошибка, а не тихая потеря строки (inner join
-- просто выбросил бы рейс, сверка бы это поймала, но без причины).
create or replace procedure dds.load_fact_flight(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_watermark timestamptz;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;
		v_rows_no_sk int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		v_watermark := etl.get_dds_watermark(p_run_id, 'dds.fact_flight');

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'DDS', 'dds.fact_flight', v_load_type)
		returning step_id into v_step_id;

		begin

			drop table if exists tmp_fact_flight;

			create temp table tmp_fact_flight as
			with candidates as (
				select f.flight_id
				from ods.ods_flight f
				where f.updated_at > v_watermark

				union

				select bp.flight_id
				from ods.ods_boarding_pass bp
				where bp.updated_at > v_watermark

				union

				select f.flight_id
				from ods.ods_flight f
				join dds.dim_route_scd2 r
					on r.route_no = f.route_no
					and f.scheduled_departure >= r.period_from
					and f.scheduled_departure < r.period_to
					and r.is_current
				left join dds.dim_airplane ap
					on ap.airplane_code = r.airplane_code
				where r.updated_at > v_watermark
					or ap.updated_at > v_watermark
			),
			boardings as (
				select
					bp.flight_id,
					count(*) as boardings
				from ods.ods_boarding_pass bp
				where bp.boarding_time is not null
					and bp.flight_id in (select c.flight_id from candidates c)
				group by bp.flight_id
			)
			select
				f.flight_id,
				r.route_sk,
				dep.airport_sk as departure_airport_sk,
				arr.airport_sk as arrival_airport_sk,
				ap.airplane_sk,
				dd.date_sk as scheduled_departure_date_sk,
				f.route_no,
				f.status,
				f.scheduled_departure,
				f.scheduled_arrival,
				f.actual_departure,
				f.actual_arrival,
				f.actual_departure is not null as is_departed,
				round(extract(epoch from f.actual_departure - f.scheduled_departure) / 60, 2) as delay_minutes,
				f.actual_departure > f.scheduled_departure + interval '15 minutes' as is_delayed,
				coalesce(b.boardings, 0)::int as boardings,
				ap.seats_total
			from candidates c
			join ods.ods_flight f
				on f.flight_id = c.flight_id
			left join dds.dim_route_scd2 r
				on r.route_no = f.route_no
				and f.scheduled_departure >= r.period_from
				and f.scheduled_departure < r.period_to
				and r.is_current
			left join dds.dim_airport dep
				on dep.airport_code = r.departure_airport
			left join dds.dim_airport arr
				on arr.airport_code = r.arrival_airport
			left join dds.dim_airplane ap
				on ap.airplane_code = r.airplane_code
			left join dds.dim_date dd
				on dd.date_sk = to_char(f.scheduled_departure at time zone 'UTC', 'YYYYMMDD')::int
			left join boardings b
				on b.flight_id = f.flight_id;

			analyze tmp_fact_flight;

			select
				count(*),
				count(*) filter (where route_sk is null
					or departure_airport_sk is null
					or arrival_airport_sk is null
					or airplane_sk is null
					or scheduled_departure_date_sk is null)
			into v_rows_read, v_rows_no_sk
			from tmp_fact_flight;

			if v_rows_no_sk > 0 then
				raise exception
					'Dimension lookup failed: % flights without surrogate key', v_rows_no_sk;
			end if;

			-- изменённые
			update dds.fact_flight ff
			set
				route_sk = t.route_sk,
				departure_airport_sk = t.departure_airport_sk,
				arrival_airport_sk = t.arrival_airport_sk,
				airplane_sk = t.airplane_sk,
				scheduled_departure_date_sk = t.scheduled_departure_date_sk,
				route_no = t.route_no,
				status = t.status,
				scheduled_departure = t.scheduled_departure,
				scheduled_arrival = t.scheduled_arrival,
				actual_departure = t.actual_departure,
				actual_arrival = t.actual_arrival,
				is_departed = t.is_departed,
				delay_minutes = t.delay_minutes,
				is_delayed = t.is_delayed,
				boardings = t.boardings,
				seats_total = t.seats_total,
				run_id = p_run_id,
				updated_at = clock_timestamp()
			from tmp_fact_flight t
			where t.flight_id = ff.flight_id;

			get diagnostics v_rows_updated = row_count;

			-- новые
			insert into dds.fact_flight (
				flight_id,
				route_sk,
				departure_airport_sk,
				arrival_airport_sk,
				airplane_sk,
				scheduled_departure_date_sk,
				route_no,
				status,
				scheduled_departure,
				scheduled_arrival,
				actual_departure,
				actual_arrival,
				is_departed,
				delay_minutes,
				is_delayed,
				boardings,
				seats_total,
				run_id
			)
			select
				t.flight_id,
				t.route_sk,
				t.departure_airport_sk,
				t.arrival_airport_sk,
				t.airplane_sk,
				t.scheduled_departure_date_sk,
				t.route_no,
				t.status,
				t.scheduled_departure,
				t.scheduled_arrival,
				t.actual_departure,
				t.actual_arrival,
				t.is_departed,
				t.delay_minutes,
				t.is_delayed,
				t.boardings,
				t.seats_total,
				p_run_id
			from tmp_fact_flight t
			where not exists (
				select 1
				from dds.fact_flight ff
				where ff.flight_id = t.flight_id
			);

			get diagnostics v_rows_inserted = row_count;

			analyze dds.fact_flight;

			drop table tmp_fact_flight;

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


-- fact_ticket_segment: ods.ods_segment + ticket (book_ref) + booking (book_date)
--   + boarding_pass (is_boarded) + dds.fact_flight (маршрут, аэропорты, дата рейса)
-- Маршрут и аэропорты берём из fact_flight, а не ищем заново: у сегмента и
-- его рейса гарантированно одинаковые ключи, и не повторяем join по периоду.
-- Сегмент пересчитывается, если изменился он сам, его билет, бронирование,
-- посадочный талон или строка его рейса в fact_flight.
create or replace procedure dds.load_fact_ticket_segment(p_run_id integer)
language plpgsql
as $$
	declare
		v_load_type varchar(20);
		v_step_id int;
		v_watermark timestamptz;
		v_rows_read int;
		v_rows_inserted int;
		v_rows_updated int;
		v_rows_no_sk int;

		v_error_code varchar(5);
		v_error_message text;
	begin

		select load_type
		into v_load_type
		from etl.etl_runs
		where run_id = p_run_id;

		v_watermark := etl.get_dds_watermark(p_run_id, 'dds.fact_ticket_segment');

		insert into etl.etl_step_logs (
			run_id,
			stage,
			table_name,
			load_type
		)
		values (p_run_id, 'DDS', 'dds.fact_ticket_segment', v_load_type)
		returning step_id into v_step_id;

		begin

			drop table if exists tmp_fact_ticket_segment;

			create temp table tmp_fact_ticket_segment as
			select
				s.ticket_no,
				s.flight_id,
				t.book_ref,
				bd.date_sk as book_date_sk,
				ff.scheduled_departure_date_sk as flight_date_sk,
				ff.route_sk,
				ff.departure_airport_sk,
				ff.arrival_airport_sk,
				s.fare_conditions,
				s.price,
				bp.boarding_time is not null as is_boarded
			from ods.ods_segment s
			join ods.ods_ticket t
				on t.ticket_no = s.ticket_no
			join ods.ods_booking b
				on b.book_ref = t.book_ref
			left join ods.ods_boarding_pass bp
				on bp.ticket_no = s.ticket_no
				and bp.flight_id = s.flight_id
			left join dds.fact_flight ff
				on ff.flight_id = s.flight_id
			left join dds.dim_date bd
				on bd.date_sk = to_char(b.book_date at time zone 'UTC', 'YYYYMMDD')::int
			where s.updated_at > v_watermark
				or t.updated_at > v_watermark
				or b.updated_at > v_watermark
				or bp.updated_at > v_watermark
				or ff.updated_at > v_watermark;

			analyze tmp_fact_ticket_segment;

			select
				count(*),
				count(*) filter (where book_date_sk is null or route_sk is null)
			into v_rows_read, v_rows_no_sk
			from tmp_fact_ticket_segment;

			if v_rows_no_sk > 0 then
				raise exception
					'Dimension lookup failed: % segments without surrogate key', v_rows_no_sk;
			end if;

			-- изменённые
			update dds.fact_ticket_segment fs
			set
				book_ref = t.book_ref,
				book_date_sk = t.book_date_sk,
				flight_date_sk = t.flight_date_sk,
				route_sk = t.route_sk,
				departure_airport_sk = t.departure_airport_sk,
				arrival_airport_sk = t.arrival_airport_sk,
				fare_conditions = t.fare_conditions,
				price = t.price,
				is_boarded = t.is_boarded,
				run_id = p_run_id,
				updated_at = clock_timestamp()
			from tmp_fact_ticket_segment t
			where t.ticket_no = fs.ticket_no
				and t.flight_id = fs.flight_id;

			get diagnostics v_rows_updated = row_count;

			-- новые
			insert into dds.fact_ticket_segment (
				ticket_no,
				flight_id,
				book_ref,
				book_date_sk,
				flight_date_sk,
				route_sk,
				departure_airport_sk,
				arrival_airport_sk,
				fare_conditions,
				price,
				is_boarded,
				run_id
			)
			select
				t.ticket_no,
				t.flight_id,
				t.book_ref,
				t.book_date_sk,
				t.flight_date_sk,
				t.route_sk,
				t.departure_airport_sk,
				t.arrival_airport_sk,
				t.fare_conditions,
				t.price,
				t.is_boarded,
				p_run_id
			from tmp_fact_ticket_segment t
			where not exists (
				select 1
				from dds.fact_ticket_segment fs
				where fs.ticket_no = t.ticket_no
					and fs.flight_id = t.flight_id
			);

			get diagnostics v_rows_inserted = row_count;

			analyze dds.fact_ticket_segment;

			drop table tmp_fact_ticket_segment;

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
-- DDS DQ: etl.check_dds
-- ТЗ п.6: целостность SCD2 - нет пересечений valid_from/valid_to, одна текущая версия.
-- ТЗ п.7: сверка суммы SOURCE <-> DDS.
--   DQ_DDS_001  версии одного периода маршрута (route_no + period_from)
--               не пересекаются по [valid_from, valid_to).
--               Пересечение: a.valid_from < b.valid_to and b.valid_from < a.valid_to.
--   DQ_DDS_002  у каждого периода маршрута ровно одна текущая версия (is_current).
--               Больше одной не даст уникальный частичный индекс, а ноль - может
--               (например, версию закрыли, а новую не вставили).
--   DQ_DDS_003  SUM(price) источника = SUM(price) в fact_ticket_segment
--               + SUM(price) отклонённых в карантин сегментов этого запуска.
--               Карантин учитываем, как в DQ_STG_008: строка, не попавшая в ODS,
--               при каждом INCREMENTAL снова приходит в STG как 'I' и снова
--               уходит в карантин -> карантин текущего запуска = все потерянные строки.
--               Если в карантин ушла изменённая строка ('U'), в DDS остаётся
--               старая цена -> FAILED (DDS отстаёт от источника - это и нужно увидеть).
-- Проверяем всё DDS, а не только пакет.
-- step_id - этап загрузки проверяемой DDS-таблицы в текущем запуске.
-- =====================================================================

create or replace procedure etl.check_dds(p_run_id integer)
language plpgsql
as $$
	declare
		v_step_id int;
		v_stg_step_id int;
		v_source_sum numeric;
		v_source_count bigint;
		v_dds_sum numeric;
		v_quarantine_sum numeric;
	begin

		-- DQ_DDS_001: версии SCD2 не пересекаются
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
			 	and sl.table_name = 'dds.dim_route_scd2'),
			'dds.dim_route_scd2',
			'DQ_DDS_001',
			'SCD2 versions of one route period must not overlap in [valid_from, valid_to)',
			'CRITICAL',
			count(*),
			count(*) filter (where m.is_overlap),
			coalesce(to_jsonb((array_agg(m.route_sk order by m.route_sk) filter (where m.is_overlap))[1:10]), '[]'),
			case
				when count(*) filter (where m.is_overlap) = 0 then 'PASSED'
				else 'FAILED'
			end
		from (
			select
				a.route_sk,
				exists (
					select 1
					from dds.dim_route_scd2 b
					where b.route_no = a.route_no
						and b.period_from = a.period_from
						and b.route_sk <> a.route_sk
						and a.valid_from < b.valid_to
						and b.valid_from < a.valid_to
				) as is_overlap
			from dds.dim_route_scd2 a
		) m;


		-- DQ_DDS_002: ровно одна текущая версия на период маршрута
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
			 	and sl.table_name = 'dds.dim_route_scd2'),
			'dds.dim_route_scd2',
			'DQ_DDS_002',
			'Each route period must have exactly one current SCD2 version',
			'CRITICAL',
			count(*),
			count(*) filter (where c.current_versions <> 1),
			coalesce(to_jsonb((array_agg(c.route_key order by c.route_key) filter (where c.current_versions <> 1))[1:10]), '[]'),
			case
				when count(*) filter (where c.current_versions <> 1) = 0 then 'PASSED'
				else 'FAILED'
			end
		from (
			select
				r.route_no || ' ' || to_char(r.period_from at time zone 'UTC', 'YYYY-MM-DD') as route_key,
				count(*) filter (where r.is_current) as current_versions
			from dds.dim_route_scd2 r
			group by r.route_no, r.period_from
		) c;


		-- DQ_DDS_003: сумма SOURCE <-> DDS
		select max(sl.step_id)
		into v_step_id
		from etl.etl_step_logs sl
		where sl.run_id = p_run_id
			and sl.table_name = 'dds.fact_ticket_segment';

		select max(sl.step_id)
		into v_stg_step_id
		from etl.etl_step_logs sl
		where sl.run_id = p_run_id
			and sl.table_name = 'stg.segments';

		select coalesce(sum(s.price), 0), count(*)
		into v_source_sum, v_source_count
		from bookings.segments s;

		select coalesce(sum(f.price), 0)
		into v_dds_sum
		from dds.fact_ticket_segment f;

		-- в карантине строка хранится как jsonb; NULL-цена (DQ_STG_003) -> coalesce
		select coalesce(sum((q.row_data ->> 'price')::numeric), 0)
		into v_quarantine_sum
		from etl.etl_quarantine q
		where q.step_id = v_stg_step_id;

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
			v_step_id,
			'dds.fact_ticket_segment',
			'DQ_DDS_003',
			'Sum of price mismatch: SOURCE <> DDS + quarantine',
			'CRITICAL',
			v_source_count,
			case
				when v_source_sum = v_dds_sum + v_quarantine_sum then 0
				else 1
			end,
			case
				when v_source_sum = v_dds_sum + v_quarantine_sum then 'PASSED'
				else 'FAILED'
			end;

	end;
$$;
