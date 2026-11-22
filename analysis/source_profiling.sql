select 
	b.book_ref,
	b.total_amount as booking_total_price,
	sum(s.price) as segment_sum,
	b.total_amount - sum(s.price) as difference
from bookings b
join tickets t using(book_ref)
join segments s using(ticket_no)
group by 
	b.book_ref,
	b.total_amount;
--having b.total_amount - sum(s.price) <> 0;


select 
	f.status,
	count(*)
from flights f
group by 
	f.status;


select 
	f.flight_id,
	f.status,
	f.scheduled_departure,
	f.actual_departure,
	extract(EPOCH from (actual_departure - scheduled_departure)) / 60 as delay_minutes
from
	flights f
where extract(EPOCH from (actual_departure - scheduled_departure)) / 60 > 15
order by delay_minutes desc;


select 
	route_no,
	count(*)
from 
	routes
group by
	route_no
having count(*) > 1;

select * from routes r;

select count(*) from flights f
union all
SELECT COUNT(*)
FROM flights f
JOIN routes r
    ON f.route_no = r.route_no
	and r.validity @> f.scheduled_departure;