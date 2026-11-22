--alter table staging.inventory add column last_update timestamp;
--alter table staging.inventory alter column last_update set not null;


drop table if exists staging.last_update;
create table staging.last_update (
	table_name varchar(50) not null,
	update_dt timestamp not null
);

drop table if exists staging.film;
create table staging.film (
	film_id int not null,
	title varchar(255) null,
	description text null,
	release_year int2 null,
	language_id int2 not null,
	rental_duration int2 not null,
	rental_rate numeric(4, 2) null,
	length int2 null,
	replacement_cost numeric(5, 2) null,
	rating varchar(10) null,
	last_update timestamp not null,
	special_features _text null,
	fulltext tsvector not null
);

--alter table staging.inventory add column deleted timestamp null;
drop table if exists staging.inventory;
create table staging.inventory (
	inventory_id int not null,
	film_id int2 not null,
	store_id int2 not null,
	last_update timestamp not null,
	deleted timestamp null
);

-- alter table staging.rental add column deleted timestamp;
drop table if exists staging.rental;
create table staging.rental (
	rental_id int not null,
	rental_date timestamp not null,
	inventory_id int4 not null,
	customer_id int2 not null,
	return_date timestamp null,
	staff_id int2 not null,
	last_update timestamp not null,
	deleted timestamp null
);


drop table if exists staging.payment;
create table staging.payment (
	payment_id int4 not null,
	customer_id int2 not null,
	staff_id int2 not null,
	rental_id int4 not null,
	amount numeric(5, 2) null,
	payment_date timestamp not null
);

--alter table staging.staff add column deleted timestamp null;
--alter table staging.staff add column last_update timestamp default to_date('2000-01-01', 'yyyy-MM-dd') not null;

drop table if exists staging.staff;
create table staging.staff (
	staff_id int4 not null,
	first_name varchar(45),
	last_name varchar(45),
	store_id int2 not null,
	last_update timestamp not null,
	deleted timestamp null
);

drop table if exists staging.address;
create table staging.address (
	address_id int4 not null,
	address varchar(50),
	district varchar(20),
	city_id int2 not null
);

drop table if exists staging.city;
create table staging.city (
	city_id int4 not null,
	city varchar(50)
);

drop table if exists staging.store;
create table staging.store (
	store_id int4 not null,
	address_id int2 not null
);

create or replace function staging.get_last_update_table(table_name varchar) returns timestamp
as $$
	begin
		return coalesce(
			(
				select
					max(update_dt)
				from
					staging.last_update lu
				where
					lu.table_name = get_last_update_table.table_name
			),
			'1900-01-01'::date
		);
	end;
$$ language plpgsql;

create or replace procedure staging.set_table_load_time(table_name varchar, current_update_dt timestamp default now()) 
as $$
	begin
		insert into staging.last_update
			(
				table_name,
			    update_dt
			)
		values(table_name, current_update_dt);
	end;
$$ language plpgsql;

create or replace procedure staging.load_film(current_date_dt timestamp) 
as $$
	begin
		truncate staging.film;
		insert into staging.film
			(
			film_id,
		    title,
		    description,
		    release_year,
		    language_id,
		    rental_duration,
		    rental_rate,
		    length,
		    replacement_cost,
		    rating,
		    last_update,
		    special_features,
		    fulltext
		    )
		select 
			film_id,
		    title,
		    description,
		    release_year,
		    language_id,
		    rental_duration,
		    rental_rate,
		    length,
		    replacement_cost,
		    rating,
		    last_update,
		    special_features,
		    fulltext
		from 
			film_src.film;
			
		call staging.set_table_load_time('staging.film', current_date_dt);
    end;
$$ language plpgsql;

create or replace procedure staging.load_inventory(current_date_dt timestamp)
as $$
	declare 
		last_update_dt timestamp;
	begin
		last_update_dt = staging.get_last_update_table('staging.inventory');
		delete from staging.inventory;
		insert into staging.inventory
			(
			inventory_id,
			film_id,
			store_id,
			last_update,
			deleted
			)
		select 
			inventory_id,
			film_id,
			store_id,
			last_update,
			deleted
		from 
			film_src.inventory i
		where i.deleted >= last_update_dt
			or i.last_update >= last_update_dt;
		
		-- after insertion the last_update table should be updated
--		delete from staging.last_update;
		call staging.set_table_load_time('staging.inventory', current_date_dt);
	end;
$$ language plpgsql;



create or replace procedure staging.load_payment()
as $$
	begin
		truncate staging.payment;
		insert into staging.payment(
			payment_id,
		    customer_id,
		    staff_id,
		    rental_id,
		    amount,
		    payment_date
   		    )
   		select 
   			payment_id,
		    customer_id,
		    staff_id,
		    rental_id,
		    amount,
		    payment_date
		from 
			film_src.payment p
	end;
$$ language plpgsql;



create or replace procedure staging.load_rental(current_date_dt timestamp)
as $$
	declare 
		last_update_dt timestamp;
	begin
		last_update_dt = staging.get_last_update_table('staging.rental');
		truncate staging.rental;  
		insert into staging.rental(
		    rental_id,
		    rental_date,
		    inventory_id,
		    customer_id,
		    return_date,
		    staff_id,
		    last_update,
		    deleted
		    )
		select
			fr.rental_id,
		    fr.rental_date,
		    fr.inventory_id,
		    fr.customer_id,
		    fr.return_date,
		    fr.staff_id,
		    fr.last_update,
		    fr.deleted
		from 
			film_src.rental fr
		where fr.deleted >= last_update_dt
			or fr.last_update >= last_update_dt; 
			
		call staging.set_table_load_time('staging.rental', current_date_dt);
	end;
$$ language plpgsql;

create or replace procedure staging.load_address()
as $$
	begin
		truncate staging.address;
		insert into staging.address (
			address_id,
		    address,
		    district,
		    city_id
    		)
    	select 
    		address_id,
		    address,
		    district,
		    city_id
    	from
    		film_src.address;
	end;
$$ language plpgsql;

create or replace procedure staging.load_staff(current_date_dt timestamp)
as $$
	declare
		last_update_dt timestamp;
	begin
		last_update_dt = staging.get_last_update_table('staging.staff');
		
		truncate staging.staff;
		insert into staging.staff (
			staff_id,
		    first_name,
		    last_name,
		    store_id,
		    deleted,
		    last_update
			)
		select 
			staff_id,
		    first_name,
		    last_name,
		    store_id,
		    deleted,
		    last_update
		from
			film_src.staff s
		where s.deleted >= last_update_dt
			or s.last_update >= last_update_dt;
			
		call staging.set_table_load_time('staging.staff', current_date_dt);
	end;
$$ language plpgsql;

create or replace procedure staging.load_city() 
as $$
	begin
		truncate staging.city;
		insert into staging.city(
			city_id,
    		city
    		)
    	select
    		city_id,
    		city
    	from 
    		film_src.city;
	end;
$$ language plpgsql;

create or replace procedure staging.load_store()
as $$
	begin
		truncate staging.store;
		insert into staging.store
		(	store_id,
    		address_id
    	)
    	select 
    		store_id,
    		address_id
    	from 	
    		film_src.store;
	end; 
$$ language plpgsql;

--call staging.load_film();
--call staging.load_inventory();
--call staging.load_payment();
--call staging.load_rental();
--call staging.load_city();
--call staging.load_address();
--call staging.load_staff();
--truncate staging.last_update;



---------------------------------------


--alter table public.inventory add column deleted timestamp null;
---- in film_src tabels are foreign tables
--create foreign table film_src.inventory (
--	inventory_id int4 options(column_name 'inventory_id') not null,
--	film_id int2 options(column_name 'film_id') not null,
--	store_id int2 options(column_name 'store_id') not null,
--	last_update timestamp options(column_name 'last_update') not null
--)
--server film_pg
--options (schema_name 'public',
--table_name 'inventory');

--alter table film_src.rental add column deleted timestamp options(column_name 'deleted') null; 

-- adding the new column from source inventory to foreign fim_src inventory
--alter table film_src.inventory add column deleted timestamp options(column_name 'deleted') null;
--select * from film_src.inventory i;