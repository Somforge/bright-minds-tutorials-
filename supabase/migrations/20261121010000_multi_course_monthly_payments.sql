
-- Multi-course monthly manual payment workflow for Bright Minds Tutorials.
-- A single payment submission covers 1-4 selected courses at K75 per course.

insert into public.course_subscription_prices
  (course_id, duration_months, price, currency, is_available)
select c.id, 1, 75.00, 'ZMW', true
from public.courses c
where c.title in ('Mathematics', 'Physics', 'Chemistry', 'Biology')
on conflict (course_id, duration_months)
do update set price = excluded.price,
              currency = excluded.currency,
              is_available = true,
              updated_at = now();

create or replace function private.submit_manual_payment(
  p_course_ids uuid[],
  p_payment_method text,
  p_transaction_reference text,
  p_proof_path text
)
returns uuid
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_course_count integer;
  v_valid_count integer;
  v_total numeric(12,2);
  v_payment_id uuid;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to submit a payment.';
  end if;

  if p_payment_method is null or p_payment_method not in ('mtn', 'airtel') then
    raise exception 'Choose MTN MoMo or Airtel Money.';
  end if;

  if length(trim(coalesce(p_transaction_reference, ''))) < 3
     or length(trim(p_transaction_reference)) > 160 then
    raise exception 'Enter a valid transaction reference.';
  end if;

  if p_course_ids is null then
    raise exception 'Select at least one course.';
  end if;

  v_course_count := cardinality(p_course_ids);
  if v_course_count < 1 or v_course_count > 4
     or (select count(distinct x) from unnest(p_course_ids) as x) <> v_course_count then
    raise exception 'Select between one and four different courses.';
  end if;

  if p_proof_path is null
     or coalesce((storage.foldername(p_proof_path))[1], '') <> v_user_id::text then
    raise exception 'A valid proof-of-payment upload is required.';
  end if;

  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'payment-proofs'
      and o.name = p_proof_path
  ) then
    raise exception 'The proof-of-payment file could not be found.';
  end if;

  select count(*), coalesce(sum(sp.price), 0)
    into v_valid_count, v_total
  from unnest(p_course_ids) selected(course_id)
  join public.courses c on c.id = selected.course_id
  join public.course_subscription_prices sp
    on sp.course_id = c.id
   and sp.duration_months = 1
   and sp.price = 75.00
   and sp.currency = 'ZMW'
   and sp.is_available = true
  where c.is_published = true
    and c.title in ('Mathematics', 'Physics', 'Chemistry', 'Biology');

  if v_valid_count <> v_course_count then
    raise exception 'One or more selected courses are unavailable. Refresh the page and try again.';
  end if;

  insert into public.payments (
    student_id, total_amount, currency, payment_method, status,
    transaction_reference, proof_of_payment_url
  )
  values (
    v_user_id, v_total, 'ZMW', p_payment_method, 'pending',
    trim(p_transaction_reference), p_proof_path
  )
  returning id into v_payment_id;

  insert into public.payment_items (
    payment_id, course_id, course_title, price_at_purchase,
    currency, duration_months, subscription_price
  )
  select
    v_payment_id, c.id, c.title, sp.price,
    'ZMW', 1, sp.price
  from unnest(p_course_ids) selected(course_id)
  join public.courses c on c.id = selected.course_id
  join public.course_subscription_prices sp
    on sp.course_id = c.id
   and sp.duration_months = 1
   and sp.price = 75.00
   and sp.currency = 'ZMW'
   and sp.is_available = true
  where c.is_published = true
    and c.title in ('Mathematics', 'Physics', 'Chemistry', 'Biology');

  return v_payment_id;
end;
$$;

revoke all on function private.submit_manual_payment(uuid[], text, text, text) from public, anon;
grant execute on function private.submit_manual_payment(uuid[], text, text, text) to authenticated;

create or replace function public.submit_manual_payment(
  p_course_ids uuid[],
  p_payment_method text,
  p_transaction_reference text,
  p_proof_path text
)
returns uuid
language sql
security invoker
set search_path = public, private, pg_temp
as $$
  select private.submit_manual_payment(
    p_course_ids, p_payment_method, p_transaction_reference, p_proof_path
  );
$$;

revoke all on function public.submit_manual_payment(uuid[], text, text, text) from public, anon;
grant execute on function public.submit_manual_payment(uuid[], text, text, text) to authenticated;

drop function if exists public.submit_manual_payment(uuid, uuid, text, text, text);
drop function if exists private.submit_manual_payment(uuid, uuid, text, text, text);
