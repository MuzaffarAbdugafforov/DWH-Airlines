--create schema core;

drop table if exists core.fact_payment;
drop table if exists core.fact_rental;
drop table if exists core.dim_date;
drop table if exists core.dim_inventory;
drop table if exists core.dim_staff;

--alter table core.dim_inventory add column effective_date_from  timestamp default to_date('1900-01-01', 'yyyy-MM-dd') not null;
--alter table core.dim_inventory add column effective_date_to timestamp default to_date('9999-01-01', 'yyyy-MM-dd') not null;
--alter table core.dim_inventory add column is_active boolean default true not null;
--alter table core.dim_inventory drop constraint dim_inventory_inventory_id_key;

--alter table core.dim_staff add column effective_date_from timestamp default to_date('1900-01-01', 'yyyy-MM-dd') not null;
--alter table core.dim_staff add column effective_date_to timestamp default to_date('9999-01-01', 'yyyy-MM-dd') not null;
--alter table core.dim_staff add column is_active boolean default true not null;

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

create table core.dim_inventory ( -- dimension 
	inventory_pk serial primary key,
	inventory_id int4 not null,
	film_id int4 not null,
	title varchar(255),
	rental_duration int2 not null,
	rental_rate numeric(4, 2),
	length int2,
	rating varchar(10),
	effective_date_from timestamp not null,
	effective_date_to timestamp not null,
	is_active boolean not null
);

create table core.dim_staff (
	staff_pk serial primary key,
	staff_id int not null,
	first_name varchar(45),
	last_name varchar(45),
	address varchar(50),
	district varchar(20),
	city_name varchar(50),
	effective_date_from timestamp not null,
	effective_date_to timestamp not null,
	is_active boolean not null
);


create table core.fact_payment ( -- fact 
	payment_pk serial primary key,
	payment_id int not null,
	amount numeric(7, 2),
	payment_date date not null,
	inventory_fk int not null references core.dim_inventory(inventory_pk),
	staff_fk int not null references core.dim_staff(staff_pk)
);

create table core.fact_rental (
	rental_pk serial primary key,
	rental_id int not null,
	inventory_fk int not null references core.dim_inventory(inventory_pk),
	staff_fk int not null references core.dim_staff(staff_pk),
	rental_date date not null,
	return_date date,
--	cnt int2 not null,
--	amount numeric(7, 2),
	effective_date_from timestamp not null,
	effective_date_to timestamp not null,
	is_active boolean not null
);

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

-- filling the core dimention tables first

create or replace procedure core.load_core_inventory()
as $$
	declare
		film_prev_update timestamp;
	begin	
--		delete from core.dim_inventory i
--		where i.inventory_id in (
--			select 
--				inv.inventory_id
--			from 
--				staging.inventory inv
--			where inv.deleted is not null
--		);

		-- from staging.inventory marking DELETED records (from existing rows in dim_inventory) 
		update core.dim_inventory di
		set
			is_active = false,
			effective_date_to = si.deleted
		from 
			staging.inventory si
		where 
			si.deleted is not null 
			and di.inventory_id = si.inventory_id
			and di.is_active is true;
			
		-- from staging.inventory capturing NEW ADDED rows (among udated and added in staging.inventory)
		create temporary table new_inventory_id_list on commit drop as
		select
			i.inventory_id
		from
			staging.inventory i
			left join core.dim_inventory di using(inventory_id)
		where 
			di.inventory_id is null;
		
		insert into core.dim_inventory
		(
			inventory_id,
			film_id,
			title,
			rental_duration,
			rental_rate,
			length,
			rating,
			effective_date_from,
			effective_date_to,
			is_active
		)
		select 
			i.inventory_id,
			f.film_id,
			f.title,
			f.rental_duration,
			f.rental_rate,
			f.length,
			f.rating,
			'1900-01-01'::date as effective_date_from,
			coalesce(i.deleted, '9999-01-01'::date) as effective_date_to,
			i.deleted is null as is_active
		from staging.inventory i
			join staging.film f using(film_id)
			join new_inventory_id_list using(inventory_id);
			
			
--		where i.deleted is null
--		on conflict (inventory_id) do update
--		set
--			film_id = excluded.film_id,
--			title = excluded.title,
--			rental_duration = excluded.rental_duration,
--			rental_rate = excluded.rental_rate,
--			length = excluded.length,
--			rating = excluded.rating;
		
		-- from staging.inventory marking UPDATED (existing) rows in dim_inventory
		update core.dim_inventory di
		set
			is_active = false,
			effective_date_to = si.last_update
		from
			staging.inventory si
			left join new_inventory_id_list idl using(inventory_id)
		where
			idl.inventory_id is null
			and si.deleted is null
			and di.inventory_id = si.inventory_id
			and di.is_active is true; 
		
		insert into core.dim_inventory
		(
			inventory_id,
			film_id,
			title,
			rental_duration,
			rental_rate,
			length,
			rating,
			effective_date_from,
			effective_date_to,
			is_active
		)
		select 
			i.inventory_id,
			f.film_id,
			f.title,
			f.rental_duration,
			f.rental_rate,
			f.length,
			f.rating,
			i.last_update as effective_date_from,
			'9999-01-01'::date as effective_date_to,
			true as is_active
		from staging.inventory i
			join staging.film f using(film_id)
			left join new_inventory_id_list idl using(inventory_id)
		where
			idl.inventory_id is null
			and i.deleted is null;
		
	-- историчность по таблице film
	
		-- берем предпоследнее значение от staging.last_update
		film_prev_update = (
			with lag_update as (
				select
					lag(lu.update_dt) over(order by lu.update_dt) lag_update_dt
				from
					staging.last_update lu
				where 
					lu.table_name = 'staging.film'
			)
			select max(lag_update_dt) from lag_update
		);
		
	-- получаем список фильмов с момента предыдущей загрузки
		create temporary table updated_film on commit drop as
		select 
			f.film_id,
			f.title,
			f.rental_duration,
			f.rental_rate,
			f.length,
			f.rating,
			f.last_update
		from
			staging.film f
		where f.last_update >= film_prev_update;
		
		create temporary table dim_inventory_to_update on commit drop as
		select
			di.inventory_pk,
			uf.last_update
		from
			core.dim_inventory di
			join updated_film uf 
				on di.film_id = uf.film_id
				and uf.last_update > di.effective_date_from
				and uf.last_update < di.effective_date_to;
				
		insert into core.dim_inventory
		(
			inventory_id,
			film_id,
			title,
			rental_duration,
			rental_rate,
			length,
			rating,
			effective_date_from,
			effective_date_to,
			is_active
		)	
		select 
			di.inventory_id,
			di.film_id,
			uf.title,
			uf.rental_duration,
			uf.rental_rate,
			uf.length,
			uf.rating,
			uf.last_update as effective_date_from,
			di.effective_date_to,
			di.is_active
		from
			core.dim_inventory di
			join dim_inventory_to_update du
				on di.inventory_pk = du.inventory_pk
			join updated_film uf 
				on di.film_id = uf.film_id;
		
		update core.dim_inventory di
		set 
			is_active = false,
		    effective_date_to = du.last_update
		from 
			dim_inventory_to_update du
		where 
			di.inventory_pk = du.inventory_pk;
		
	end;
$$ language plpgsql;

 
create or replace procedure core.load_core_staff() 
as $$
	begin
--		delete from core.dim_staff s
--		where s.staff_id in 
--			(
--				select
--					s.staff_id
--				from
--					staging.staff s
--				where s.deleted is not null
--			);
		
		-- handling DELETED rows from staging.staff
		update core.dim_staff ds
		set
			is_active = false,
			effective_date_to = ss.deleted
		from staging.staff ss
		where ds.is_active is true
			and ss.deleted is not null
			and ds.staff_id = ss.staff_id;
			
		-- handling new ADDED rows from staging.staff
		create temporary table new_staff_id_list on commit drop as
		select 
			ss.staff_id
		from
			staging.staff ss
			left join core.dim_staff ds using(staff_id)
		where 
			ds.staff_id is null;

		insert into core.dim_staff
			(
			    staff_id,
			    first_name,
			    last_name,
			    address,
			    district,
			    city_name,
			    effective_date_from,
			    effective_date_to,
			    is_active
			)
		select 
			s.staff_id,
			s.first_name,
			s.last_name,
			a.address,
			a.district,
			c.city,
			s.last_update as effective_date_from,
			coalesce(s.deleted, '9999-01-01'::date) as effective_date_to,
			s.deleted is null as is_active
		from
			staging.staff s
			join staging.store st using(store_id)
			join new_staff_id_list sid using(staff_id)
			join staging.address a using(address_id)
			join staging.city c using(city_id);
			
			
		-- handling UPDATE in existing rows from staging.staff
		update core.dim_staff ds
		set
			is_active = false,
			effective_date_to = ss.last_update
		from
			staging.staff ss
			left join new_staff_id_list sid using(staff_id)
		where sid.staff_id is null
			and ds.staff_id = ss.staff_id
			and ds.is_active is true
			and ss.deleted is null;
			
		insert into core.dim_staff
			(
			    staff_id,
			    first_name,
			    last_name,
			    address,
			    district,
			    city_name,
			    effective_date_from,
			    effective_date_to,
			    is_active
			)
		select 
			s.staff_id,
			s.first_name,
			s.last_name,
			a.address,
			a.district,
			c.city,
			s.last_update as effective_date_from,
			'9999-01-01'::date as effective_date_to,
			true as is_active
		from
			staging.staff s
			left join new_staff_id_list sid using(staff_id)
			join staging.store st on s.store_id = st.store_id
			join staging.address a using(address_id)
			join staging.city c using(city_id)
		where 
			s.deleted is null 
			and sid.staff_id is null;
		
--		where s.deleted is null
--		on conflict (staff_id) do update
--		set
--			staff_id = excluded.staff_id,
--			first_name = excluded.first_name,
--			last_name = excluded.last_name,
--			address = excluded.address,
--			district = excluded.district,
--			city_name = excluded.city_name;
	end;
$$ language plpgsql;

create or replace procedure core.load_core_payment() 
as $$
	begin
		delete from core.fact_payment;
		insert into core.fact_payment
			(
				payment_id,
			    amount,
			    payment_date,
			    inventory_fk,
			    staff_fk
			)
		select 
			p.payment_id,
			p.amount,
			p.payment_date::date as payment_date,
			di.inventory_pk as inventory_fk,
			ds.staff_pk as staff_fk
		from
			staging.payment p
			join staging.rental r using(rental_id)
			join core.dim_inventory di 
				on r.inventory_id = di.inventory_id 
				and p.payment_date between di.effective_date_from and di.effective_date_to
			join core.dim_staff ds on p.staff_id = ds.staff_id
			join core.dim_date dt on dt.date_actual = p.payment_date::date;
	end;
$$ language plpgsql;

create or replace procedure core.load_core_rental()
as $$
	begin
	
		-- mark DELETED from staging.rental
		update core.fact_rental r
		set
			is_active = false,
			effective_date_to = sr.deleted
		from 
			staging.rental sr
		where 
			r.rental_id = sr.rental_id
			and r.is_active is true
			and sr.deleted is not null;
			
			
		-- NEW ADDED rows to staging.rental
		create temporary table new_rental_id_list on commit drop as
		select 
			sr.rental_id
		from
			staging.rental sr
			left join core.fact_rental fr using(rental_id)
		where fr.rental_id is null;

		insert into core.fact_rental 
			(
			    inventory_fk,
			    rental_id,
			    staff_fk,
			    rental_date,
			    return_date,	
--			    cnt,
--    			amount,
    			effective_date_from,
    			effective_date_to,
    			is_active
    		)
    	select 
    		di.inventory_pk as inventory_fk,
    		r.rental_id,
    		ds.staff_pk as staff_fk,
    		r.rental_date::date as rental_date,
    		r.return_date::date as return_date,	
--    		count(*) as cnt,
--    		sum(sp.amount) as amount,
    		r.last_update as effective_date_from,
    		coalesce(r.deleted, '9999-01-01'::date) as effective_date_to,
    		r.deleted is null as is_active
    	from
    		staging.rental r
    		join new_rental_id_list rid using(rental_id)
    		join core.dim_inventory di 
    			on r.inventory_id = di.inventory_id  
    			and r.rental_date between di.effective_date_from and di.effective_date_to
    		join core.dim_staff ds on ds.staff_id = r.staff_id
    		join core.dim_date dt_rental on dt_rental.date_actual = r.rental_date::date
--    		left join staging.payment sp using(rental_id)
    		left join core.dim_date dt_return on dt_return.date_actual = r.return_date::date;
--    	group by
--    		r.rental_id,
--  			di.inventory_pk,
--  			ds.staff_pk,
--  			r.rental_date::date,
--  			r.return_date::date;

		-- handling UPDATED rows (получаем список фактов сдачи в аренду, по которым только проставлена дата возврата)
		create temporary table update_return_date_id_list on commit drop as
		select 
			r.rental_id
		from
			staging.rental r
			join core.fact_rental fr using(rental_id)
			join core.dim_inventory di on fr.inventory_fk = di.inventory_pk
			join core.dim_staff ds on ds.staff_id = r.staff_id
			join core.dim_date dd on fr.rental_date = dd.date_actual
			left join new_rental_id_list rid using(rental_id)
		where 
			r.return_date is not null
			and fr.return_date is null
			and fr.is_active is true
			and di.inventory_id = r.inventory_id
			and ds.staff_id = r.staff_id
			and dd.date_actual = r.return_date::date
			and r.deleted is null 
			and rid.rental_id is null;
			
		-- проставляем дату возврата у фактов сдачи в аренду, у которых была только проставлена дата возврата
		update core.fact_rental fr	
		set
			return_date = sr.last_update
		from 
			staging.rental sr	
			join update_return_date_id_list urdl using(rental_id)
			join core.dim_date dd on dd.date_actual = sr.return_date::date
		where
			fr.rental_id = sr.rental_id
			and fr.is_active is true;
			
		-- помечаем измененные факты сдачи в аренду не активными
		update core.fact_rental fr
		set
			is_active = false,
			effective_date_to = sr.last_update
		from
			staging.rental sr
			left join update_return_date_id_list urdl using(rental_id) 
			left join new_rental_id_list rid using(rental_id)
		where
			fr.rental_id = sr.rental_id
			and fr.is_active is true
			and sr.deleted is null
			and urdl.rental_id is null
			and rid.rental_id is null;
		
		insert into core.fact_rental 
			(
			    inventory_fk,
			    rental_id,
			    staff_fk,
			    rental_date,
			    return_date,	
--			    cnt,
--    			amount,
    			effective_date_from,
    			effective_date_to,
    			is_active
    		)
    	select 
    		di.inventory_pk as inventory_fk,
    		r.rental_id,
    		ds.staff_pk as staff_fk,
    		r.rental_date::date as rental_date,
    		r.return_date::date as return_date,	
--    		count(*) as cnt,
--    		sum(sp.amount) as amount,
    		r.last_update as effective_date_from,
    		'9999-01-01'::date as effective_date_from,
    		true as is_active
    	from
    		staging.rental r
    		left join new_rental_id_list rid using(rental_id)
    		join core.dim_inventory di 
    			on r.inventory_id = di.inventory_id  
    			and r.rental_date between di.effective_date_from and di.effective_date_to
    		join core.dim_staff ds on ds.staff_id = r.staff_id
    		join core.dim_date dt_rental on dt_rental.date_actual = r.rental_date::date
--    		left join staging.payment sp using(rental_id)
    		left join core.dim_date dt_return on dt_return.date_actual = r.return_date::date
    		left join update_return_date_id_list urdl using(rental_id) 
    	where
    		rid.rental_id is null
    		and r.deleted is null
    		and urdl.rental_id is null;
	end;
$$ language plpgsql;

create or replace procedure core.delete_fact()
as $$
	begin
		delete from core.fact_payment;
		delete from core.fact_rental;
	end;
$$ language plpgsql;


create or replace procedure core.full_load()
as $$
	declare
		current_date_dt timestamp = now();
	begin
		call staging.load_film(current_date_dt);
		call staging.load_inventory(current_date_dt);
		call staging.load_payment();
		call staging.load_rental(current_date_dt);
		call staging.load_city();
		call staging.load_address();
		call staging.load_staff(current_date_dt);
		call staging.load_store();
		
		
--		call core.delete_fact();
		call core.load_core_inventory();
		call core.load_core_staff();
		call core.load_core_payment();
		call core.load_core_rental();
	end;
$$ language plpgsql;

call core.load_date('2005-01-01'::date, 8035);
call core.full_load();	

select * from core.fact_payment;
select * from core.fact_rental fr order by fr.rental_id desc;
select * from staging.rental;