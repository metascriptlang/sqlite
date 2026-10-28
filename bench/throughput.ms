// Driver throughput against bench/baseline.c, the same work in plain C on the same amalgamation:
// `msc run --release bench/throughput.ms`. One line per workload: `<db> <workload> <ns/op> <check>`.
import { Database, SqliteError, integer, named, real, text } from "../src/index";
import { exists, remove } from "std/fs";

const ROWS: int32 = 100000;
const LOOKUPS: int32 = 10000;
const WAL_PATH = "/tmp/msq-bench-ms.db";

struct Row {
	id: int64;
	name: string;
	score: float64;
	n: int64;
}

struct Mode {
	journal_mode: string;
}

struct Values {
	name: string;
	score: float64;
	n: int64;
}

function fail(error: SqliteError): string {
	return error.toString();
}

function checked<T>(r: Result<T, SqliteError>): Result<T, string> {
	return r.ok ? Result.ok(r.value) : Result.err(r.error.toString());
}

// Not checked<void>: a generic read of r.value instantiated with void fails clang
// (/tmp/msqrepro/voidGeneric.ms).
function done(r: Result<void, SqliteError>): Result<void, string> {
	return r.ok ? Result.ok(null) : Result.err(r.error.toString());
}

function report(db: string, label: string, startMs: float64, ops: int32, check: int64): void {
	const ns = (performance.now() - startMs) * 1000000 / (ops as float64);
	console.log(`${db} ${label} ${Math.round(ns)} ${check}`);
}

function nameOf(i: int32): string {
	return i % 2 == 0 ? "web-1" : "web-2";
}

function scoreOf(i: int32): float64 {
	return (i % 100) as float64 / 4;
}

function workloads(label: string, db: Database): Result<void, string> {
	const schema = "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, n INTEGER);" +
		"CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT, score REAL, n INTEGER)";
	try done(db.exec(schema));

	let start = performance.now();
	try db.transaction((): Result<void, string> => {
		for (let i: int32 = 0; i < ROWS; i++) {
			try checked(db.run("INSERT INTO t (name, score, n) VALUES (?, ?, ?)", [
				text(nameOf(i)), real(scoreOf(i)), integer(i as int64),
			]));
		}
		return Result.ok(null);
	}, fail);
	report(label, "insert_positional", start, ROWS, ROWS as int64);

	start = performance.now();
	try db.transaction((): Result<void, string> => {
		for (let i: int32 = 0; i < ROWS; i++) {
			const values: Values = { name: nameOf(i), score: scoreOf(i), n: i as int64 };
			try checked(db.run("INSERT INTO u (name, score, n) VALUES (:name, :score, :n)", named(values)));
		}
		return Result.ok(null);
	}, fail);
	report(label, "insert_named", start, ROWS, ROWS as int64);

	start = performance.now();
	const rows = try checked(db.query<Row>("SELECT id, name, score, n FROM t", []));
	let sum: int64 = 0;
	for (const row of rows) {
		sum += row.id + row.n + (row.name.byteLength() as int64) + ((row.score * 4) as int64);
	}
	report(label, "query_struct", start, rows.length, sum);

	start = performance.now();
	const json = try checked(db.queryJson("SELECT id, name, score, n FROM t", []));
	report(label, "query_json", start, ROWS, json.byteLength() as int64);

	start = performance.now();
	let found: int64 = 0;
	for (let i: int32 = 0; i < LOOKUPS; i++) {
		const id = ((i * 7919) % ROWS + 1) as int64;
		const row = try checked(db.queryOne<Row>(
			"SELECT id, name, score, n FROM t WHERE id = ?", [integer(id)],
		));
		if (row != null) found += row!.n;
	}
	report(label, "query_one", start, LOOKUPS, found);
	return done(db.close());
}

function main(): Result<void, string> {
	try workloads("memory", try checked(Database.open(":memory:")));
	for (const suffix of ["", "-wal", "-shm"]) {
		if (exists(WAL_PATH + suffix)) remove(WAL_PATH + suffix);
	}
	const wal = try checked(Database.open(WAL_PATH));
	try checked(wal.queryOne<Mode>("PRAGMA journal_mode=WAL", []));
	try workloads("wal", wal);
	return Result.ok(null);
}

when (!testBuild) {
	const outcome = main();
	if (!outcome.ok) console.log(`bench failed: ${outcome.error}`);
}
