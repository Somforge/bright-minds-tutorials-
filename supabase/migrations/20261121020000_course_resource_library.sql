create table if not exists public.course_resources (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  module_id uuid null references public.modules(id) on delete set null,
  title text not null check (length(trim(title)) between 2 and 180),
  resource_type text not null check (resource_type in ('lecture_note','tutorial_sheet','past_paper','solution','other')),
  description text null,
  academic_year integer null check (academic_year is null or academic_year between 1900 and 2100),
  resource_path text not null unique,
  original_file_name text not null,
  mime_type text not null,
  file_size_bytes bigint not null check (file_size_bytes > 0),
  is_published boolean not null default false,
  uploaded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists course_resources_course_idx
  on public.course_resources(course_id, is_published, created_at desc);
create index if not exists course_resources_module_idx
  on public.course_resources(module_id);

alter table public.course_resources enable row level security;

drop policy if exists "Admins manage course resources" on public.course_resources;
create policy "Admins manage course resources"
  on public.course_resources for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "Subscribed students view published course resources" on public.course_resources;
create policy "Subscribed students view published course resources"
  on public.course_resources for select to authenticated
  using (
    is_published = true
    and exists (
      select 1 from public.subscriptions s
      where s.course_id = course_resources.course_id
        and s.student_id = auth.uid()
        and s.status = 'active'
        and (s.start_date is null or s.start_date <= now())
        and (s.end_date is null or s.end_date > now())
    )
  );

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'course-resources',
  'course-resources',
  false,
  20971520,
  array[
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'image/jpeg',
    'image/png'
  ]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Admins upload course resources" on storage.objects;
create policy "Admins upload course resources"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'course-resources' and public.is_admin());

drop policy if exists "Admins update course resource files" on storage.objects;
create policy "Admins update course resource files"
  on storage.objects for update to authenticated
  using (bucket_id = 'course-resources' and public.is_admin())
  with check (bucket_id = 'course-resources' and public.is_admin());

drop policy if exists "Admins delete course resource files" on storage.objects;
create policy "Admins delete course resource files"
  on storage.objects for delete to authenticated
  using (bucket_id = 'course-resources' and public.is_admin());

drop policy if exists "Admins and subscribed students read course resource files" on storage.objects;
create policy "Admins and subscribed students read course resource files"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'course-resources'
    and (
      public.is_admin()
      or exists (
        select 1
        from public.course_resources cr
        join public.subscriptions s on s.course_id = cr.course_id
        where cr.resource_path = storage.objects.name
          and cr.is_published = true
          and s.student_id = auth.uid()
          and s.status = 'active'
          and (s.start_date is null or s.start_date <= now())
          and (s.end_date is null or s.end_date > now())
      )
    )
  );
