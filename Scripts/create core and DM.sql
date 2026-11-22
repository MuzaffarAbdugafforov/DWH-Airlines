drop table if exists report.sales_date;
drop table if exists report.sales_film;
drop table if exists core.fact_payment;
drop table if exists core.fact_rental;
drop table if exists dim_date;
drop table if exists core.dim_inventory;
drop table if exists core.dim_staff;

create table core.dim_date
(
  date_dim_pk INT primary key,
  date_actual DATE not null,
  epoch BIGINT not null,
  day_suffix VARCHAR(4) not null,
  day_name VARCHAR(9) not null,
  day_of_week INT not null,
  day_of_month INT not null,
  day_of_quarter INT not null,
  day_of_year INT not null,
  week_of_month INT not null,
  week_of_year INT not null,
  week_of_year_iso CHAR(10) not null,
  month_actual INT not null,
  month_name VARCHAR(9) not null,
  month_name_abbreviated CHAR(3) not null,
  quarter_actual INT not null,
  quarter_name VARCHAR(9) not null,
  year_actual INT not null,
  first_day_of_week DATE not null,
  last_day_of_week DATE not null,
  first_day_of_month DATE not null,
  last_day_of_month DATE not null,
  first_day_of_quarter DATE not null,
  last_day_of_quarter DATE not null,
  first_day_of_year DATE not null,
  last_day_of_year DATE not null,
  mmyyyy CHAR(6) not null,
  mmddyyyy CHAR(10) not null,
  weekend_indr BOOLEAN not null
);

create index dim_date_date_actual_idx
on core.dim_date(date_actual);

create table core.dim_inventory ( -- dimension 
	inventory_pk serial primary key,
	inventory_id int4 not null,
	film_id int4 not null,
	title varchar(255),
	rental_duration int2 not null,
	rental_rate numeric(4, 2),
	length int2,
	rating varchar(10)
);


create table dim_staff (
	staff_pk serial primary key,
	staff_id int not null,
	first_name varchar(45),
	last_name varchar(45),
	address varchar(50),
	district varchar(20),
	city_name varchar(50)
);


create table fact_payment ( -- fact 
	payment_pk serial primary key,
	payment_id int not null,
	amount numeric(7, 2),
	payment_date_fk integer not null references core.dim_date(date_dim_pk),
	inventory_fk int not null references dim_inventory(inventory_pk),
	staff_fk int not null references dim_staff(staff_pk)
);

create table fact_rental (
	rental_pk serial primary key,
	rental_id int not null,
	inventory_fk int not null references dim_inventory(inventory_pk),
	staff_fk int not null references dim_staff(staff_pk),
	rental_date_fk integer not null references core.dim_date(date_dim_pk),
	return_date_fk integer references core.dim_date(date_dim_pk),
	cnt int2 not null,
	amount numeric(7, 2)
);

create table report.sales_date ( -- dm tables
	date_title varchar(20) not null,
	amount numeric(7, 2) not null,
	date_sort integer not null
);

create table report.sales_film (
	title varchar(255),
	amount numeric(7, 2)
);

-- filling the core dimention tables first

create or replace procedure core.load_date(sdate date, nm integer)
as $$
	begin
		insert into core.dim_date
		select
			TO_CHAR(datum, 'yyyymmdd')::INT as date_dim_pk,
			datum as date_actual,
			extract(EPOCH from datum) as epoch,
			TO_CHAR(datum, 'fmDDth') as day_suffix,
			TO_CHAR(datum, 'TMDay') as day_name,
			extract(ISODOW from datum) as day_of_week,
			extract(day from datum) as day_of_month,
			datum - DATE_TRUNC('quarter', datum)::DATE + 1 as day_of_quarter,
			extract(DOY from datum) as day_of_year,
			TO_CHAR(datum, 'W')::INT as week_of_month,
			extract(WEEK from datum) as week_of_year,
			extract(ISOYEAR from datum) || TO_CHAR(datum, '"-W"IW-') || extract(ISODOW from datum) as week_of_year_iso,
			extract(month from datum) as month_actual,
			TO_CHAR(datum, 'TMMonth') as month_name,
			TO_CHAR(datum, 'Mon') as month_name_abbreviated,
			extract(QUARTER from datum) as quarter_actual,
			case
				when extract(QUARTER from datum) = 1 then 'First'
				when extract(QUARTER from datum) = 2 then 'Second'
				when extract(QUARTER from datum) = 3 then 'Third'
				when extract(QUARTER from datum) = 4 then 'Fourth'
			end as quarter_name,
			extract(year from datum) as year_actual,
			datum + (1 - extract(ISODOW from datum))::INT as first_day_of_week,
			datum + (7 - extract(ISODOW from datum))::INT as last_day_of_week,
			datum + (1 - extract(day from datum))::INT as first_day_of_month,
			(DATE_TRUNC('MONTH', datum) + interval '1 MONTH - 1 day')::DATE as last_day_of_month,
			DATE_TRUNC('quarter', datum)::DATE as first_day_of_quarter,
			(DATE_TRUNC('quarter', datum) + interval '3 MONTH - 1 day')::DATE as last_day_of_quarter,
			TO_DATE(extract(year from datum) || '-01-01', 'YYYY-MM-DD') as first_day_of_year,
			TO_DATE(extract(year from datum) || '-12-31', 'YYYY-MM-DD') as last_day_of_year,
			TO_CHAR(datum, 'mmyyyy') as mmyyyy,
			TO_CHAR(datum, 'mmddyyyy') as mmddyyyy,
			case
				when extract(ISODOW from datum) in (6, 7) then true
				else false
			end as weekend_indr
		from
			(
			select
				sdate + SEQUENCE.DAY as datum
			from
				GENERATE_SERIES(0, nm - 1) as sequence (day)
			order by
				SEQUENCE.DAY) DQ
		order by 1;
	end;

$$ language plpgsql;

create or replace procedure core.load_inventory()
as $$
	begin	
		delete from core.dim_inventory;
		insert into core.dim_inventory
		(
			inventory_id,
			film_id,
			title,
			rental_duration,
			rental_rate,
			length,
			rating
		)
		select 
			i.inventory_id,
			f.film_id,
			f.title,
			f.rental_duration,
			f.rental_rate,
			f.length,
			f.rating
		from staging.inventory i
			join staging.film f using(film_id);
	end;
$$ language plpgsql;


create or replace procedure core.load_staff() 
as $$
	begin
		delete from core.dim_staff;
		insert into core.dim_staff
			(
			    staff_id,
			    first_name,
			    last_name,
			    address,
			    district,
			    city_name
			)
		select 
			s.staff_id,
			s.first_name,
			s.last_name,
			a.address,
			a.district,
			c.city
		from
			staging.staff s
			join staging.store st using(store_id)
			join staging.address a using(address_id)
			join staging.city c using(city_id);
	end;
$$ language plpgsql;

create or replace procedure core.load_payment() 
as $$
	begin
		delete from core.fact_payment;
		insert into core.fact_payment
			(
				payment_id,
			    amount,
			    payment_date_fk,
			    inventory_fk,
			    staff_fk
			)
		select 
			p.payment_id,
			p.amount,
			dt.date_dim_pk as payment_date_fk,
			di.inventory_pk as inventory_fk,
			ds.staff_pk as staff_fk
		from
			staging.payment p
			join staging.rental r using(rental_id)
			join core.dim_inventory di using(inventory_id)
			join core.dim_staff ds on p.staff_id = ds.staff_id
			join core.dim_date dt on dt.date_actual = p.payment_date::date;
	end;
$$ language plpgsql;

create or replace procedure core.load_rental()
as $$
	begin
		insert into core.fact_rental 
			(
			    inventory_fk,
			    rental_id,
			    staff_fk,
			    rental_date_fk,
			    return_date_fk,	
			    cnt,
    			amount
    		)
    	select 
    		di.inventory_pk as inventory_fk,
    		r.rental_id,
    		ds.staff_pk as staff_fk,
    		dt_rental.date_dim_pk as rental_date_fk,
    		dt_return.date_dim_pk as return_date_fk,	
    		count(*) as cnt,
    		sum(sp.amount) as amount
    	from
    		staging.rental r 
    		join core.dim_inventory di using(inventory_id)
    		join core.dim_staff ds on ds.staff_id = r.staff_id
    		join core.dim_date dt_rental on dt_rental.date_actual = r.rental_date::date
    		left join staging.payment sp using(rental_id)
    		left join core.dim_date dt_return on dt_return.date_actual = r.return_date::date
    	group by
    		r.rental_id,
  			di.inventory_pk,
  			ds.staff_pk,
  			dt_rental.date_dim_pk,
  			dt_return.date_dim_pk;
	end;
$$ language plpgsql;

create or replace procedure core.delete_fact()
as $$
	begin
		delete from core.fact_payment;
		delete from core.fact_rental;
	end;
$$ language plpgsql;


create or replace procedure report.sales_date_calc()
as $$
	begin
		delete from report.sales_date;
		insert into report.sales_date
			(
				date_title,
				amount,
				date_sort
			)
		select 
			dt.day_suffix || ' ' || dt.month_name || ' ' || dt.year_actual,
			sum(fp.amount) as amount,
			dt.date_dim_pk as date_sort
		from
			core.fact_payment fp 
			join core.dim_date dt
				on fp.payment_date_fk = dt.date_dim_pk
		group by
			dt.day_suffix || dt.month_name || dt.year_actual,
			dt.date_dim_pk;
	end;
$$ language plpgsql;

create or replace procedure report.sales_film_calc()
as $$
	begin 
		insert into report.sales_film
			(
			title,
		    amount
		    )
		select di.title, sum(fp.amount) from core.fact_payment fp
		join core.dim_inventory di on di.inventory_pk  = fp.inventory_fk
		group by di.title;

	end;
$$ language plpgsql;

create or replace procedure core.full_load()
as $$
	begin
		call staging.load_film();
		call staging.load_inventory();
		call staging.load_payment();
		call staging.load_rental();
		call staging.load_city();
		call staging.load_address();
		call staging.load_staff();
		call staging.load_store();
		
		
		call core.delete_fact();
		call core.load_inventory();
		call core.load_staff();
		call core.load_payment();
		call core.load_rental();
		
		call report.sales_date_calc();
		call report.sales_film_calc();
	end;
$$ language plpgsql;




call core.load_date('2005-01-01'::date, 8035);
call core.full_load();

select * from report.sales_film sf;
select * from report.sales_date sd;

select * from core.dim_inventory di 
where di.inventory_id = 4583;