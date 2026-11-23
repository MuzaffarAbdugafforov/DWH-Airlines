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
