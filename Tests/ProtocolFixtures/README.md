# Protocol fixtures

Copies of the language-neutral protocol cases these tests read: each schema file has `valid` (and some `invalid`)
examples, and `scenarios/` holds scripted exchanges the SDK must replay exactly. The server and every pingfront
SDK run the same cases. They are copied in for each release; `keys.json` leaves out the cases with secret-key-shaped
values (this SDK checks public keys only, and `KeyTests` covers a pasted secret key).
