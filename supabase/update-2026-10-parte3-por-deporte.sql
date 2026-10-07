drop policy if exists "gift_cards admin" on public.gift_cards;
create policy "gift_cards admin" on public.gift_cards for all to authenticated using (can_manage_sport(sport)) with check (can_manage_sport(sport));
drop policy if exists "group_requests admin" on public.group_requests;
create policy "group_requests admin" on public.group_requests for all to authenticated using (can_manage_sport(sport)) with check (can_manage_sport(sport));
