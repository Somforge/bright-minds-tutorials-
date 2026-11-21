-- Manual payment workflow for Bright Minds Tutorials.
-- Apply only after reviewing this migration. It creates private proof storage,
-- student-owned submission access, and admin-only approval that activates subscriptions.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'payment-proofs',
  'payment-proofs',
  false,
  5242880,
  array['image/jpeg','image/png','image/webp','application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Students upload their own payment proofs" on storage.objects;
create policy "Students upload their own payment proofs"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'payment-proofs'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Students and admins view payment proofs" on storage.objects;
create policy "Students and admins view payment proofs"
on storage.objects for select to authenticated
using (
  bucket_id = 'payment-proofs'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_admin()
  )
);

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create or replace function private.submit_manual_payment(
  p_course_id uuid,
  p_price_id uuid,
  p_payment_method text,
  p_transaction_reference text,
  p_proof_path text
)
returns uuid
language plpgsql
security definer
set search_path = public, storage, pg_temp
as $
declare
  v_user_id uuid := auth.uid();
  v_course_title text;
  v_price numeric(12,2);
  v_duration integer;
  v_payment_id uuid;
begin
  if v_user_id is null then
    raise exception 'You must be signed in to submit a payment.';
  end if;

  if p_payment_method is null or p_payment_method not in ('mtn', 'airtel', 'bank_transfer') then
    raise exception 'Choose a valid payment method.';
  end if;

  if length(trim(coalesce(p_transaction_reference, ''))) < 3
     or length(trim(p_transaction_reference)) > 160 then
    raise exception 'Enter a valid transaction reference.';
  end if;

  if p_proof_path is null
     or coalesce((storage.foldername(p_proof_path))[1], '') <> v_user_id::text then
    raise exception 'A valid proof-of-payment upload is required.';
  end if;

  select c.title, sp.price, sp.duration_months
    into v_course_title, v_price, v_duration
  from public.courses c
  join public.course_subscription_prices sp on sp.course_id = c.id
  where c.id = p_course_id
    and sp.id = p_price_id
    and c.is_published = true
    and sp.is_available = true;

  if not found then
    raise exception 'This course or subscription option is no longer available.';
  end if;

  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'payment-proofs'
      and o.name = p_proof_path
  ) then
    raise exception 'The proof-of-payment file could not be found.';
  end if;

  insert into public.payments (
    student_id, total_amount, currency, payment_method, status,
    transaction_reference, proof_of_payment_url
  )
  values (
    v_user_id, v_price, 'ZMW', p_payment_method, 'pending',
    trim(p_transaction_reference), p_proof_path
  )
  returning id into v_payment_id;

  insert into public.payment_items (
    payment_id, course_id, course_title, price_at_purchase,
    currency, duration_months, subscription_price
  )
  values (
    v_payment_id, p_course_id, v_course_title, v_price,
    'ZMW', v_duration, v_price
  );

  return v_payment_id;
end;
$$;

revoke all on function private.submit_manual_payment(uuid, uuid, text, text, text) from public, anon;
grant execute on function private.submit_manual_payment(uuid, uuid, text, text, text) to authenticated;

create or replace function public.submit_manual_payment(
  p_course_id uuid, p_price_id uuid, p_payment_method text,
  p_transaction_reference text, p_proof_path text
)
returns uuid
language sql
security invoker
set search_path = public, private, pg_temp
as $
  select private.submit_manual_payment(
    p_course_id, p_price_id, p_payment_method, p_transaction_reference, p_proof_path
  );
$;
revoke all on function public.submit_manual_payment(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.submit_manual_payment(uuid, uuid, text, text, text) to authenticated;

create or replace function private.admin_review_manual_payment(
  p_payment_id uuid,
  p_decision text,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_payment public.payments%rowtype;
  v_item record;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Only an administrator can review payments.';
  end if;

  if p_decision is null or p_decision not in ('verified', 'rejected') then
    raise exception 'Choose verified or rejected.';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment not found.';
  end if;

  if v_payment.status <> 'pending' then
    raise exception 'This payment has already been reviewed.';
  end if;

  if p_decision = 'verified' then
    update public.payments
    set status = 'verified',
        verification_notes = nullif(trim(coalesce(p_notes, '')), ''),
        verified_by = auth.uid(),
        verified_at = now(),
        updated_at = now()
    where id = p_payment_id;

    for v_item in
      select id, course_id, duration_months
      from public.payment_items
      where payment_id = p_payment_id
    loop
      insert into public.subscriptions (
        student_id, course_id, status, start_date, end_date,
        payment_id, payment_item_id
      )
      values (
        v_payment.student_id,
        v_item.course_id,
        'active',
        now(),
        now() + make_interval(months => coalesce(v_item.duration_months, 1)),
        p_payment_id,
        v_item.id
      );
    end loop;
  else
    update public.payments
    set status = 'rejected',
        verification_notes = nullif(trim(coalesce(p_notes, '')), ''),
        verified_by = auth.uid(),
        verified_at = now(),
        updated_at = now()
    where id = p_payment_id;
  end if;
end;
$$;

revoke all on function private.admin_review_manual_payment(uuid, text, text) from public, anon;
grant execute on function private.admin_review_manual_payment(uuid, text, text) to authenticated;

create or replace function public.admin_review_manual_payment(
  p_payment_id uuid, p_decision text, p_notes text default null
)
returns void
language sql
security invoker
set search_path = public, private, pg_temp
as $
  select private.admin_review_manual_payment(p_payment_id, p_decision, p_notes);
$;
revoke all on function public.admin_review_manual_payment(uuid, text, text) from public, anon;
grant execute on function public.admin_review_manual_payment(uuid, text, text) to authenticated;
