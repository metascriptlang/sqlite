// Several connections on one WAL database file, as a server holds them: a held write lock makes
// another writer wait out its busy timeout, readers keep their snapshot while a writer commits,
// and the same holds between threads and between OS processes.
import { lockedRead, lockedUpdate } from "std/core/promise";
import { exists, remove } from "std/fs";
import { ChildProcess, ChildStream, spawn as startProcess } from "std/process";
import { Database, DEFAULT_OPEN_OPTIONS, ErrorCode, OpenOptions, SqliteError } from "../src/index";

// Relative to the repository root, where `msc test test/contention.ms` runs.
const CHILD_PROGRAM = "test/contentionChild.ms";

struct Count { n: int64; }

struct Progress { writing: boolean; }

function opened(path: string, busyTimeoutMs: int32): Database {
	const options: OpenOptions = { ...DEFAULT_OPEN_OPTIONS, busyTimeoutMs };
	const r = Database.open(path, options);
	if (!r.ok) throw new Error(r.error.toString());
	return r.value;
}

// A new database file in WAL mode holding an empty table t.
function walDatabase(name: string): string {
	const nonce = `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
	const path = `/tmp/msqlite-contention-${name}-${nonce}.db`;
	const db = opened(path, 0);
	const setup = db.exec("PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER)");
	if (!setup.ok) throw new Error(setup.error.toString());
	const closed = db.close();
	if (!closed.ok) throw new Error(closed.error.toString());
	return path;
}

function removeDatabase(path: string): void {
	for (const file of [path, `${path}-wal`, `${path}-shm`]) {
		if (exists(file)) remove(file);
	}
}

function rowsOf(db: Database): int64 {
	const r = db.queryOne<Count>("SELECT COUNT(*) AS n FROM t", []);
	if (!r.ok) throw new Error(r.error.toString());
	if (r.value == null) throw new Error("COUNT(*) returned no row");
	return r.value!.n;
}

// Runs on a worker thread with a connection of its own, opened and closed there: records that
// it is about to write, then inserts and gives how many milliseconds the insert took.
function timedInsert(path: string, progress: Locked<Progress>): Result<float64, SqliteError> {
	const db = try Database.open(path);
	const started = performance.now();
	lockedUpdate(progress, (_: Progress): Progress => ({ writing: true }));
	try db.run("INSERT INTO t VALUES (2)", []);
	const took = performance.now() - started;
	try db.close();
	return Result.ok(took);
}

// Reads the child's stdout until `line` has arrived; false when it ends or stalls first.
function awaitLine(child: ChildProcess, line: string): boolean {
	let seen = "";
	while (!seen.contains(line)) {
		const chunk = child.read(ChildStream.Stdout, 60000);
		if (!chunk.ok || chunk.value.ended) return false;
		seen += chunk.value.data;
	}
	return true;
}

test "a held write lock fails another writer with Busy once its busy timeout has passed" {
	const path = walDatabase("busy");
	const holder = opened(path, 0);
	const waiter = opened(path, 100);
	assert holder.exec("BEGIN IMMEDIATE").ok;
	const started = performance.now();
	const blocked = waiter.run("INSERT INTO t VALUES (1)", []);
	const waited = performance.now() - started;
	assert !blocked.ok && blocked.error.code == ErrorCode.Busy;
	assert waited >= 100 && waited < 1000, `waited ${waited} ms`;
	assert holder.exec("COMMIT").ok;
	assert holder.close().ok && waiter.close().ok;
	removeDatabase(path);
}

test "a reader keeps its snapshot while another connection commits, and sees it after" {
	const path = walDatabase("snapshot");
	const writer = opened(path, 0);
	const reader = opened(path, 0);
	assert reader.exec("BEGIN").ok;
	assert rowsOf(reader) == 0;
	assert writer.run("INSERT INTO t VALUES (1)", []).ok;
	assert rowsOf(reader) == 0;
	assert reader.exec("COMMIT").ok;
	assert rowsOf(reader) == 1;
	assert writer.close().ok && reader.close().ok;
	removeDatabase(path);
}

test "a writer on another thread waits for the lock holder's commit within its timeout" {
	const path = walDatabase("wait");
	const holder = opened(path, 0);
	assert holder.exec("BEGIN IMMEDIATE; INSERT INTO t VALUES (1)").ok;
	const progress = new Locked<Progress>({ writing: false });
	const insert = spawn(() => timedInsert(path, progress));
	while (!lockedRead(progress, (p: Progress): boolean => p.writing)) await sleepAsync(1);
	await sleepAsync(150);
	assert holder.exec("COMMIT").ok;
	const took = await insert;
	assert took.ok, took.ok ? "" : took.error.toString();
	assert took.value >= 150 && took.value < 5000, `the insert took ${took.value} ms`;
	assert rowsOf(holder) == 2;
	assert holder.close().ok;
	removeDatabase(path);
}

test "a write lock held by another OS process is Busy here until that process commits" {
	const path = walDatabase("process");
	const started = startProcess("msc", ["run", CHILD_PROGRAM, path]);
	assert started.ok;
	const child = started.value;
	assert awaitLine(child, "locked\n"), child.takeStderr();
	const db = opened(path, 100);
	const blocked = db.run("INSERT INTO t VALUES (2)", []);
	assert !blocked.ok && blocked.error.code == ErrorCode.Busy;
	assert child.write("commit\n", 5000).ok;
	const exit = child.wait(30000);
	assert exit.ok && exit.value.code == 0, child.takeStderr();
	child.close();
	assert db.run("INSERT INTO t VALUES (2)", []).ok;
	assert rowsOf(db) == 2;
	assert db.close().ok;
	removeDatabase(path);
}
