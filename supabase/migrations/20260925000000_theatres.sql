-- Adds the Theatre & shows category: 11 London theatres and comedy/cabaret venues
insert into public.venues (id,name,cat,kind,area,addr,lat,lng,google_place_id) values
('p54','Piccadilly Theatre','West End musical','Theatre','Piccadilly','16 Denman St, London W1D 7DY',51.51095,-0.13558,'ChIJZ98vDNQEdkgRJE51ZgjyTaE'),
('p55','Theatre Royal Drury Lane','West End musical','Theatre','Covent Garden','Catherine St, London WC2B 5JF',51.51285,-0.12037,'ChIJj91E_coEdkgRlUibJh13Jws'),
('p56','Gillian Lynne Theatre','West End show','Theatre','Covent Garden','166 Drury Ln, London WC2B 5PW',51.51532,-0.12258,'ChIJ7eA75soEdkgRZXtgpYnGHYI'),
('p57','Palace Theatre','West End play','Theatre','Soho','113 Shaftesbury Ave, London W1D 5AY',51.51319,-0.12945,'ChIJYxVJmtIEdkgRSFNK6hLhPvQ'),
('p58','The Criterion Theatre','Comedy musical','Theatre','Piccadilly','218-223 Piccadilly, London W1J 9HR',51.50973,-0.13427,'ChIJJSck4NMEdkgR-oXVKxbGNbw'),
('p59','@sohoplace','New theatre','Theatre','Soho','4 Soho Pl, Charing Cross Rd, London W1D 3BG',51.51571,-0.13061,'ChIJazKQ6Z0bdkgRTkmUhLKe2kM'),
('p60','The Old Vic','Drama theatre','Theatre','Waterloo','103 The Cut, London SE1 8NB',51.50206,-0.10931,'ChIJZU00SboEdkgRl0iY1cDec9k'),
('p61','National Theatre','Drama theatre','Theatre','South Bank','London SE1 9PX',51.50722,-0.11437,'ChIJdYvbqaMEdkgRDdOt_IfsYRc'),
('p62','The Top Secret Comedy Club','Stand-up comedy','Theatre','Covent Garden','170a Drury Ln, London WC2B 5PD',51.51539,-0.12309,'ChIJ6zivZswEdkgR8Vd0G2Df5KE'),
('p63','The London Cabaret Club','Dinner cabaret','Theatre','Bloomsbury','The Bloomsbury Ballroom, Bloomsbury Square, London WC1B 4DA',51.51888,-0.12187,'ChIJkzlMivEPdkgRgn5iDCYesp8'),
('p64','Getaway Comedy, Soho','Stand-up comedy','Theatre','Soho','Zebrano, 18 Greek St, London W1D 4DS',51.51406,-0.13036,'ChIJAQCUKtIEdkgRLmGJ_deAP08')
on conflict (id) do nothing;
