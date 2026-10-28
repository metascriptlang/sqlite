// Direct calls against actors on one WAL file: per-call latency, pipelined CALLs, group commit
// behind a SEND, and reads spread over several reader actors. `msc run --release bench/actors.ms`.
import { Database, Param, SqliteError, named } from "../src/index";
import { remove } from "std/fs";

const ROWS: int32 = 20000;
const READS: int32 = 400000;
const BATCH: int32 = 256;

struct Row {
	id: int64;
	host: string;
	busy: float64;
}

function openFile(path: string): Database {
	const opened = Database.open(path);
	if (!opened.ok) throw new Error(opened.error.toString());
	const db = opened.value;
	db.exec("PRAGMA journal_mode = WAL");
	return db;
}

function must<T>(result: Result<T, SqliteError>): T {
	if (!result.ok) throw new Error(result.error.toString());
	return result.value;
}

function done(result: Result<void, SqliteError>): void {
	if (!result.ok) throw new Error(result.error.toString());
}

function rowFor(id: int32): Row {
	return { id: id as int64, host: `host-${id % 16}`, busy: (id % 100) as float64 / 100.0 };
}

function busyOf(db: Database, id: int64): float64 {
	const sql = "SELECT id, host, busy FROM samples WHERE id = ?";
	const row = must(db.get<Row>(sql, [Param.integer(id)]));
	return row == null ? -1.0 : row.busy;
}

actor Reader {
	private db: Database;
	constructor(path: string) { this.db = openFile(path); }
	get(id: int64): float64 {
		return busyOf(this.db, id);
	}
	getMany(first: int32, count: int32): float64 {
		let total = 0.0;
		must(this.db.run("BEGIN"));
		for (let i: int32 = 0; i < count; i++) {
			total += busyOf(this.db, ((first + i) % ROWS + 1) as int64);
		}
		must(this.db.run("COMMIT"));
		return total;
	}
}

actor Writer {
	private db: Database;
	private pending: int32 = 0;
	constructor(path: string) { this.db = openFile(path); }
	record(row: Row): void {
		if (this.pending == 0) must(this.db.run("BEGIN IMMEDIATE"));
		must(this.db.run("INSERT INTO samples VALUES (:id, :host, :busy)", named(row)));
		this.pending += 1;
		if (this.pending == BATCH) {
			must(this.db.run("COMMIT"));
			this.pending = 0;
		}
	}
	flush(): int32 {
		if (this.pending > 0) must(this.db.run("COMMIT"));
		this.pending = 0;
		return 0;
	}
}

function report(name: string, operations: int32, startedMs: float64): void {
	const elapsed = performance.now() - startedMs;
	const perOp = elapsed * 1000000.0 / (operations as float64);
	console.log(`${name}: ${Math.round(perOp)} ns/op (${Math.round(elapsed)} ms)`);
}

function scratch(name: string): string {
	return `/tmp/msqlite-actors-${name}-${Date.now()}.db`;
}

function removeDatabase(path: string): void {
	remove(path);
	remove(`${path}-wal`);
	remove(`${path}-shm`);
}

function createSchema(db: Database): void {
	done(db.exec("CREATE TABLE samples (id INTEGER PRIMARY KEY, host TEXT, busy REAL)"));
}

async function writes(): Promise<void> {
	const directPath = scratch("direct-write");
	const direct = openFile(directPath);
	createSchema(direct);
	let started = performance.now();
	for (let i: int32 = 1; i <= ROWS; i++) {
		must(direct.run("INSERT INTO samples VALUES (:id, :host, :busy)", named(rowFor(i))));
	}
	report("write, direct, one commit per row", ROWS, started);
	done(direct.close());
	removeDatabase(directPath);

	const actorPath = scratch("actor-write");
	const setup = openFile(actorPath);
	createSchema(setup);
	done(setup.close());
	const writer = new Writer(actorPath);
	started = performance.now();
	for (let i: int32 = 1; i <= ROWS; i++) writer.record(rowFor(i));
	await writer.flush();
	report(`write, actor SEND, commit per ${BATCH}`, ROWS, started);
	removeDatabase(actorPath);
}

async function reads(): Promise<void> {
	const path = scratch("read");
	const db = openFile(path);
	createSchema(db);
	must(db.run("BEGIN"));
	for (let i: int32 = 1; i <= ROWS; i++) {
		must(db.run("INSERT INTO samples VALUES (:id, :host, :busy)", named(rowFor(i))));
	}
	must(db.run("COMMIT"));

	let started = performance.now();
	let total = 0.0;
	for (let i: int32 = 0; i < READS; i++) {
		const row = must(db.get<Row>(
			"SELECT id, host, busy FROM samples WHERE id = ?",
			[Param.integer((i % ROWS + 1) as int64)],
		));
		if (row != null) total += row.busy;
	}
	report("read, direct", READS, started);

	const one = new Reader(path);
	started = performance.now();
	for (let i: int32 = 0; i < READS; i++) total += await one.get((i % ROWS + 1) as int64);
	report("read, actor CALL, awaited one by one", READS, started);

	for (const readers of [1, 2, 4, 8]) {
		const pool: Reader[] = [];
		for (let r: int32 = 0; r < readers; r++) pool.push(new Reader(path));
		const share = READS / readers;
		started = performance.now();
		const parts: Promise<float64>[] = [];
		for (let r: int32 = 0; r < readers; r++) parts.push(pool[r].getMany(r * share, share));
		const sums = await Promise.all(parts);
		for (const sum of sums) total += sum;
		report(`read, ${readers} reader actors in parallel`, READS, started);
	}
	console.log(`checksum ${Math.round(total)}`);
	done(db.close());
	removeDatabase(path);
}

when (!testBuild) {
	await writes();
	await reads();
}
