create schema report;

create table report.sales_date (
	date_title varchar(20) not null,
	amount numeric(7, 2) not null,
	date_sort integer not null
);

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

create or replace procedure full_load()
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
	end;
$$ language plpgsql;


call full_load();
select * from report.sales_date sd order by date_sort;

select di.title, sum(fp.amount) from core.fact_payment fp
join core.dim_inventory di on di.inventory_pk  = fp.inventory_fk
group by di.title;