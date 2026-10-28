// A database owned by an application actor: the app's messages, not a generic SQL proxy, cross
// threads; the connection stays with the actor that opened it.
import { Database, named } from "../src/index";

struct Sample {
	host: string;
	busy: float64;
}

actor Samples {
	private db: Database | null = null;
	private failure: string | null = null;

	constructor(path: string) {
		const opened = Database.open(path);
		if (!opened.ok) {
			this.failure = opened.error.toString();
			return;
		}
		const db = opened.value;
		const migrated = db.migrate([
			"CREATE TABLE samples (host TEXT NOT NULL, " +
				"busy REAL NOT NULL CHECK (busy BETWEEN 0 AND 1))",
		]);
		if (!migrated.ok) {
			this.failure = migrated.error.toString();
			return;
		}
		this.db = db;
	}

	// A send has no reply, so a failed insert is kept and reported by the next call.
	record(sample: Sample): void {
		const db = this.db;
		if (db == null) return;
		const inserted = db.run("INSERT INTO samples VALUES (:host, :busy)", named(sample));
		if (!inserted.ok && this.failure == null) this.failure = inserted.error.toString();
	}

	busiest(): Result<Sample | null, string> {
		const failure = this.failure;
		if (failure != null) return Result.err(failure);
		const db = this.db;
		if (db == null) return Result.err("the database is not open");
		const found = db.queryOne<Sample>(
			"SELECT host, busy FROM samples ORDER BY busy DESC LIMIT 1",
			[],
		);
		return found.ok ? Result.ok(found.value) : Result.err(found.error.toString());
	}
}

test "an actor owning a database applies sends in order before a later call" {
	const samples = new Samples(":memory:");
	samples.record({ host: "web-1", busy: 0.4 });
	samples.record({ host: "web-2", busy: 0.9 });
	const top = await samples.busiest();
	assert top.ok && top.value != null;
	assert top.value.host == "web-2" && top.value.busy == 0.9;
}

test "a failed send reaches the next call" {
	const samples = new Samples(":memory:");
	samples.record({ host: "web-1", busy: 1.5 });
	const top = await samples.busiest();
	assert !top.ok && top.error.contains("CHECK constraint failed");
}

test "a database that did not open reaches the first call" {
	const samples = new Samples("/nonexistent-dir/samples.db");
	const top = await samples.busiest();
	assert !top.ok && top.error.contains("unable to open database file");
}
