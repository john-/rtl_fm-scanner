CREATE TABLE freqs (
        freq real not null,
        label varchar(50),
        bank varchar(50),
        source varchar(10) not null,
        entered date,
        lat real,
        long real,
        pass integer default 0,
        count integer default 0,
        unique (freq,bank)
);

CREATE TRIGGER insert_add_time after insert on freqs
begin
    update freqs set entered = datetime('NOW')  where rowid = new.rowid;
end;
