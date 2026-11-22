-- ETL tables
-- ТЗ п.6: аудит - run_id, имя этапа, начало/конец, статус, количество
-- прочитанных/вставленных/обновлённых/отклонённых строк, сообщение ошибки.
-- Структура взята из etl_lab (etl.etl_runs, etl.etl_step_logs).


--drop table if exists etl.etl_dq_results;
--drop table if exists etl.etl_step_logs;
--drop table if exists etl.etl_runs;


create table if not exists etl.etl_runs (
	run_id serial primary key,
	load_type varchar(20) not null,
	status varchar(20) not null default 'RUNNING',
	started_at timestamptz not null default clock_timestamp(),
	ended_at timestamptz,
	error_message text,

	constraint ck_etl_runs_load_type
		check (load_type in ('FULL', 'INCREMENTAL')),
	constraint ck_etl_runs_status
		check (status in ('RUNNING', 'SUCCESS', 'FAILED')),
	constraint ck_etl_runs_running_ended
		check ((status = 'RUNNING') = (ended_at is null)),
	constraint ck_etl_runs_dates
		check (ended_at is null or ended_at >= started_at),
	constraint ck_etl_runs_error_message
		check (status = 'FAILED' or error_message is null)
);


create table if not exists etl.etl_step_logs (
	step_id serial primary key,
	run_id integer not null,
	stage varchar(10) not null,
	table_name text not null,
	load_type varchar(20) not null,
	status varchar(20) not null default 'RUNNING',
	started_at timestamptz not null default clock_timestamp(),
	ended_at timestamptz,
	rows_read integer not null default 0,
	rows_inserted integer not null default 0,
	rows_updated integer not null default 0,
	rows_rejected integer not null default 0,
	error_message text,

	constraint fk_etl_step_logs_run
		foreign key (run_id) references etl.etl_runs (run_id),
	constraint ck_etl_step_logs_stage
		check (stage in ('RAW', 'STG', 'ODS', 'DDS', 'DM')),
	constraint ck_etl_step_logs_load_type
		check (load_type in ('FULL', 'INCREMENTAL')),
	constraint ck_etl_step_logs_status
		check (status in ('RUNNING', 'SUCCESS', 'FAILED')),
	constraint ck_etl_step_logs_running_ended
		check ((status = 'RUNNING') = (ended_at is null)),
	constraint ck_etl_step_logs_dates
		check (ended_at is null or ended_at >= started_at),
	constraint ck_etl_step_logs_rows
		check (
			rows_read >= 0
			and rows_inserted >= 0
			and rows_updated >= 0
			and rows_rejected >= 0
		),
	constraint ck_etl_step_logs_error_message
		check (status = 'FAILED' or error_message is null)
);


-- ТЗ п.7: не менее 10 исполняемых проверок с сохранением результатов
-- (DQ rule, дата/запуск, число нарушений, примеры ключей).
-- Одна строка = результат одного правила в одном запуске DQ-проверки.
-- step_id - этап самой DQ-проверки (table_name = 'DQ_CHECK' в etl_step_logs, как в etl_lab).

create table if not exists etl.etl_dq_results (
	dq_result_id serial primary key,
	run_id integer not null,
	step_id integer not null,
	table_name text not null,
	rule_code varchar(20) not null,
	rule_description text not null,
	severity varchar(20) not null,
	rows_checked integer not null default 0,
	violations_count integer not null default 0,
	sample_keys jsonb not null default '[]'::jsonb,
	status varchar(20) not null,
	checked_at timestamptz not null default clock_timestamp(),

	constraint fk_etl_dq_results_run
		foreign key (run_id) references etl.etl_runs (run_id),
	constraint fk_etl_dq_results_step
		foreign key (step_id) references etl.etl_step_logs (step_id),
	constraint ck_etl_dq_results_severity
		check (severity in ('WARNING', 'ERROR', 'CRITICAL')),
	constraint ck_etl_dq_results_status
		check (status in ('PASSED', 'FAILED')),
	constraint ck_etl_dq_results_counts
		check (rows_checked >= 0 and violations_count >= 0),
	constraint ck_etl_dq_results_passed
		check ((status = 'PASSED') = (violations_count = 0)),
	constraint ck_etl_dq_results_sample_keys
		check (jsonb_typeof(sample_keys) = 'array')
);


create index if not exists ix_etl_dq_results_run_id on etl.etl_dq_results (run_id);
create index if not exists ix_etl_dq_results_step_id on etl.etl_dq_results (step_id);
create index if not exists ix_etl_dq_results_rule_code on etl.etl_dq_results (rule_code);

