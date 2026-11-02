update plans set active = false
where coalesce(sport, 'sup') = 'sup' and active and name not in ('Pack 8 clases', 'Pack 4 clases');

insert into plans (name, description, price, classes, days_valid, active, sport, sort)
select 'Pack 8 clases', '2 salidas por semana durante un mes', 90000, 8, 30, true, 'sup', 1
where not exists (select 1 from plans where sport = 'sup' and name = 'Pack 8 clases');

insert into plans (name, description, price, classes, days_valid, active, sport, sort)
select 'Pack 4 clases', '1 salida por semana durante un mes', 65000, 4, 30, true, 'sup', 2
where not exists (select 1 from plans where sport = 'sup' and name = 'Pack 4 clases');

select name, price, classes, days_valid, round(price / classes) as por_clase, active from plans where coalesce(sport, 'sup') = 'sup' order by active desc, sort;
