-- Orchestration
-- ТЗ §6: общая процедура orchestration; модули RAW / STG / ODS / DDS / DM + отдельные DQ-проверки.
-- Запуск:
--   call etl.run_pipeline('FULL');         -- первая полная загрузка
--   call etl.run_pipeline('INCREMENTAL');  -- пакеты 2 и 3, повторный запуск, перезапуск после сбоя
--
-- Порядок: RAW → check_raw → STG → check_stg → ODS → check_ods → DDS → check_dds → DM.
-- После каждого слоя commit: шаги и счётчики видны сразу в etl.etl_step_logs,
-- а то, что уже загружено, сохраняется при сбое следующего слоя.
-- Если в слое есть FAILED шаг → run закрывается FAILED, следующие слои НЕ запускаются
-- (ошибочные данные не доходят до DM, ТЗ §7).
-- Перезапуск после сбоя: исправить причину → call etl.run_pipeline('INCREMENTAL').
--   RAW всегда полный снапшот, STG/ODS сравнивают hash с ODS, DDS берёт строки по watermark
--   последнего SUCCESS шага → догружается только то, что не дошло.
--
-- Важно: процедура делает commit внутри → вызывать в режиме auto-commit DBeaver
-- (не внутри begin ... rollback и не из DO-блока).


-- Закрыть run: SUCCESS, если нет FAILED шагов, иначе FAILED
create or replace procedure etl.finish_run(p_run_id integer)
language plpgsql
as $$
	declare
		v_failed_steps int;
	begin

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

		raise notice 'run_id = % finished, failed steps = %', p_run_id, v_failed_steps;
	end;
$$;


drop procedure if exists etl.run_pipeline(varchar);

create or replace procedure etl.run_pipeline(p_load_type varchar)
language plpgsql
as $$
	declare
		v_run_id int;
	begin

		insert into etl.etl_runs (load_type)
		values (p_load_type)
		returning run_id into v_run_id;

		commit;
		raise notice '% run_id = % (%) started', clock_timestamp(), v_run_id, p_load_type;


		-- RAW: всегда полный снапшот источника
		call raw.load_bookings(v_run_id);
		call raw.load_tickets(v_run_id);
		call raw.load_segments(v_run_id);
		call raw.load_flights(v_run_id);
		call raw.load_boarding_passes(v_run_id);
		call raw.load_routes(v_run_id);
		call raw.load_airports_data(v_run_id);
		call raw.load_airplanes_data(v_run_id);
		call raw.load_seats(v_run_id);

		call etl.check_raw(v_run_id);

		commit;
		raise notice '% RAW done', clock_timestamp();

		if exists (select 1 from etl.etl_step_logs where run_id = v_run_id and status = 'FAILED') then
			call etl.finish_run(v_run_id);
			return;
		end if;


		-- STG: дельта RAW vs ODS по ключу + row_hash, карантин
		call stg.load_bookings(v_run_id);
		call stg.load_tickets(v_run_id);
		call stg.load_segments(v_run_id);
		call stg.load_flights(v_run_id);
		call stg.load_boarding_passes(v_run_id);
		call stg.load_routes(v_run_id);
		call stg.load_airports(v_run_id);
		call stg.load_airplanes(v_run_id);
		call stg.load_seats(v_run_id);

		call etl.check_stg(v_run_id);

		commit;
		raise notice '% STG done', clock_timestamp();

		if exists (select 1 from etl.etl_step_logs where run_id = v_run_id and status = 'FAILED') then
			call etl.finish_run(v_run_id);
			return;
		end if;


		-- ODS: родители → дети (FK)
		call ods.clear_ods(v_run_id);          -- только для FULL
		call ods.load_airport(v_run_id);
		call ods.load_airplane(v_run_id);
		call ods.load_seat(v_run_id);          -- после airplane
		call ods.load_route(v_run_id);         -- после airport + airplane
		call ods.load_flight(v_run_id);        -- после route (для DQ_ODS_001)
		call ods.load_booking(v_run_id);
		call ods.load_ticket(v_run_id);        -- после booking
		call ods.load_segment(v_run_id);       -- после ticket + flight
		call ods.load_boarding_pass(v_run_id); -- после segment

		call etl.check_ods(v_run_id);

		commit;
		raise notice '% ODS done', clock_timestamp();

		if exists (select 1 from etl.etl_step_logs where run_id = v_run_id and status = 'FAILED') then
			call etl.finish_run(v_run_id);
			return;
		end if;


		-- DDS: измерения → факты
		call dds.load_dim_date(v_run_id);
		call dds.load_dim_airport(v_run_id);
		call dds.load_dim_airplane(v_run_id);
		call dds.load_dim_route_scd2(v_run_id);
		call dds.load_fact_flight(v_run_id);         -- после измерений
		call dds.load_fact_ticket_segment(v_run_id); -- после fact_flight (берёт из него sk)

		call etl.check_dds(v_run_id);

		commit;
		raise notice '% DDS done', clock_timestamp();

		if exists (select 1 from etl.etl_step_logs where run_id = v_run_id and status = 'FAILED') then
			call etl.finish_run(v_run_id);
			return;
		end if;


		-- DM: полный пересчёт витрин из DDS
		call dm.load_sales_routes(v_run_id);
		call dm.load_flight_performance(v_run_id);

		commit;
		raise notice '% DM done', clock_timestamp();

		call etl.finish_run(v_run_id);
	end;
$$;


-- Запуск
call etl.run_pipeline('FULL');
-- call etl.run_pipeline('INCREMENTAL');


-- Результат последнего запуска
select * from etl.etl_runs order by run_id desc limit 5;

select stage, table_name, status, rows_read, rows_inserted, rows_updated, rows_rejected,
	ended_at - started_at as duration, error_message
from etl.etl_step_logs
where run_id = (select max(run_id) from etl.etl_runs)
order by step_id;

select rule_code, table_name, severity, rows_checked, violations_count, status
from etl.etl_dq_results
where run_id = (select max(run_id) from etl.etl_runs)
order by dq_result_id;
