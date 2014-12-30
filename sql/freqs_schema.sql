create table freqs (
        frequency varchar(10) not null,
	designator varchar(50),
	groups varchar(50),
	source varchar(10) not null,
	time date,
        lat real,
	long real,
	pass integer,
	unique (frequency,designator)
);

create trigger insert_add_time after insert on freqs
begin
    update freqs set time = datetime('NOW')  where rowid = new.rowid;
end;
