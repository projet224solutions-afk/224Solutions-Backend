-- Create vendor_credit_sales table
create table if not exists vendor_credit_sales (
  id uuid default gen_random_uuid() primary key,
  vendor_id uuid not null references vendors(id) on delete cascade,
  order_number text not null unique,
  customer_id uuid references customers(id) on delete set null,
  customer_name text not null,
  customer_phone text,
  items jsonb not null default '[]',
  subtotal numeric not null default 0,
  tax numeric not null default 0,
  total numeric not null default 0,
  paid_amount numeric not null default 0,
  remaining_amount numeric not null default 0,
  status text not null default 'pending' check (status in ('pending', 'partial', 'paid', 'overdue')),
  due_date timestamp not null,
  notes text,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  updated_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Create indexes
create index if not exists idx_vendor_credit_sales_vendor_id on vendor_credit_sales(vendor_id);
create index if not exists idx_vendor_credit_sales_customer_id on vendor_credit_sales(customer_id);
create index if not exists idx_vendor_credit_sales_status on vendor_credit_sales(status);
create index if not exists idx_vendor_credit_sales_due_date on vendor_credit_sales(due_date);

-- Enable RLS
alter table vendor_credit_sales enable row level security;

-- RLS Policies for vendor
create policy if not exists "Vendors can view their own credit sales"
  on vendor_credit_sales for select
  using (auth.uid()::text = (select user_id from vendors where id = vendor_id)::text);

create policy if not exists "Vendors can create credit sales"
  on vendor_credit_sales for insert
  with check (auth.uid()::text = (select user_id from vendors where id = vendor_id)::text);

create policy if not exists "Vendors can update their own credit sales"
  on vendor_credit_sales for update
  using (auth.uid()::text = (select user_id from vendors where id = vendor_id)::text)
  with check (auth.uid()::text = (select user_id from vendors where id = vendor_id)::text);

create policy if not exists "Vendors can delete their own credit sales"
  on vendor_credit_sales for delete
  using (auth.uid()::text = (select user_id from vendors where id = vendor_id)::text);

-- Create function to update overdue status
create or replace function update_overdue_credit_sales()
returns void as $$
begin
  update vendor_credit_sales
  set status = 'overdue'
  where status in ('pending', 'partial')
    and due_date < now()
    and remaining_amount > 0;
end;
$$ language plpgsql security definer;

-- Create trigger to automatically update status on insert/update
create trigger if not exists tr_vendor_credit_sales_updated_at
before update on vendor_credit_sales
for each row
execute function update_timestamp();
