-- Optional: gives every active merchant a category, a tagline and a sample menu so the customer app has stores to show.
-- Remove a merchant's sample menu later with:  delete from public.products where merchant_id = '<merchant id>';
do $$
declare m record; i int := 0; cats text[] := array['Food','Groceries','Pharmacy','Electronics']; c text;
begin
  for m in select id from public.profiles where role = 'merchant' and status = 'active' loop
    c := cats[1 + i % 4]; i := i + 1;
    update public.profiles set category = c, blurb = coalesce(blurb, 'Fast, fresh and checked at your door') where id = m.id;
    if not exists (select 1 from public.products where merchant_id = m.id) then
      insert into public.products (merchant_id, name, description, price, category)
      select m.id, v.n, v.d, v.p, 'Popular' from (values
        ('Food','Jollof rice bowl','Smoky rice with chicken',6.50),('Food','Grilled chicken wrap','Warm wrap with slaw',5.00),('Food','Crispy fries','Large portion',2.50),('Food','Fresh juice','Chilled, 500 ml',2.00),
        ('Groceries','Rice, 5 kg','Long grain',9.00),('Groceries','Eggs, tray of 30','Farm fresh',4.50),('Groceries','Milk, 1 L','Full cream',1.80),('Groceries','Bread loaf','Baked today',2.20),
        ('Pharmacy','Pain relief','16 tablets',3.00),('Pharmacy','Vitamin C','30 tablets',4.50),('Pharmacy','Hand sanitiser','250 ml',2.00),('Pharmacy','First aid kit','Compact kit',8.00),
        ('Electronics','USB-C cable','1 m, fast charging',5.00),('Electronics','Wireless earbuds','Up to 20 h battery',25.00),('Electronics','Power bank','10,000 mAh',18.00),('Electronics','Phone case','Shock resistant',6.00)
      ) v(k, n, d, p) where v.k = c;
    end if;
  end loop;
end $$;
