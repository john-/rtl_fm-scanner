CREATE TABLE freqs (
        freq_key		SERIAL PRIMARY KEY,
	freq			DOUBLE PRECISION NOT NULL,
	label			TEXT NOT NULL,
	bank			TEXT NOT NULL,
	source			TEXT NOT NULL,
	entered			TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
	pass			INTEGER DEFAULT 0,
	UNIQUE			(freq, bank)
);

GRANT SELECT,INSERT,UPDATE ON freqs TO script;
GRANT SELECT,UPDATE ON freqs_freq_key_seq TO script;
