// A SQLite connection with identity: one owner, explicit close, a prepared-statement cache,
// typed reads and nestable transactions. Native only.
import {
	sqlite3, sqlite3_stmt, msqAutocommit, msqBusyTimeout, msqChanges, msqClose, msqCloseLater,
	msqErrorMessage, msqExec, msqExtendedCode, msqLastInsertRowid, msqOpen, msqPrepare,
	msqStatementCount,
} from "./native/sqlite.h";
import { Connection, SQLITE_OK, StatementHandle, codeFailure, failure, misuse } from "./native";
import { ErrorCode, SqliteError, errorCodeOf } from "./error";
import { Named, Param, blob, integer, maybe, named, nullParam, real, text } from "./param";
import { ColumnKind, Statement } from "./statement";
import { exists, remove } from "std/fs";
import { rowDecode, rowFields } from "./decode";
import { rowsJson } from "./json";

const SQLITE_SCHEMA: int32 = 17;
const OPEN_READONLY: int32 = 1;
const OPEN_READWRITE: int32 = 2;
const OPEN_CREATE: int32 = 4;
const OPEN_URI: int32 = 64;
const OPEN_NOMUTEX: int32 = 32768;
const OPEN_FULLMUTEX: int32 = 65536;

export enum OpenMode {
	ReadWriteCreate,
	ReadWrite,
	ReadOnly,
}

// SingleOwner: one owner uses the connection at a time (an actor, or one thread); sqlite takes
// no connection mutex. Serialized: sqlite locks the connection on every call.
export enum Threading {
	SingleOwner,
	Serialized,
}

export struct OpenOptions {
	mode: OpenMode;
	threading: Threading;
	busyTimeoutMs: int32;
	statementCacheSize: int32;
}

export const DEFAULT_OPEN_OPTIONS: OpenOptions = {
	mode: OpenMode.ReadWriteCreate,
	threading: Threading.SingleOwner,
	busyTimeoutMs: 5000,
	statementCacheSize: 64,
};

struct UserVersion {
	user_version: int32;
}

export struct RunResult {
	changes: int64;
	lastInsertRowid: int64;
}

function openFlags(options: OpenOptions): int32 {
	const mode = match (options.mode) {
		OpenMode.ReadWriteCreate => OPEN_READWRITE | OPEN_CREATE,
		OpenMode.ReadWrite => OPEN_READWRITE,
		OpenMode.ReadOnly => OPEN_READONLY,
	};
	const threading = match (options.threading) {
		Threading.SingleOwner => OPEN_NOMUTEX,
		Threading.Serialized => OPEN_FULLMUTEX,
	};
	return mode | threading | OPEN_URI;
}

export class Database {
	readonly path: string;
	private connection: Connection;
	private cache: Map<string, Statement> = new Map<string, Statement>();
	private stepping: Set<string> = new Set<string>();
	private cacheSize: int32;
	private depth: int32 = 0;

	constructor(path: string, connection: Connection, cacheSize: int32) {
		this.path = path;
		this.connection = connection;
		this.cacheSize = cacheSize;
	}

	static open(
		path: string,
		options: OpenOptions = DEFAULT_OPEN_OPTIONS,
	): Result<Database, SqliteError> {
		let pointer: Ptr<sqlite3>;
		const rc = msqOpen(path, openFlags(options), out pointer);
		if (rc != SQLITE_OK) {
			if (pointer == null) return Result.err(codeFailure(rc, ""));
			const error: SqliteError = {
				code: errorCodeOf(rc),
				extended: msqExtendedCode(pointer),
				message: `${msqErrorMessage(pointer) as string}: ${path}`,
				sql: "",
			};
			msqCloseLater(pointer);
			return Result.err(error);
		}
		const connection = new Connection(pointer);
		if (options.busyTimeoutMs > 0) {
			const rc = msqBusyTimeout(pointer, options.busyTimeoutMs);
			if (rc != SQLITE_OK) return Result.err(connection.failure(rc, ""));
		}
		return Result.ok(new Database(path, connection, options.statementCacheSize));
	}

	get isOpen(): boolean {
		return this.connection.pointer != null;
	}

	// Statements prepared on this connection and not yet finalized, cached ones included.
	openStatements(): int32 {
		const pointer = this.connection.pointer;
		return pointer == null ? 0 : msqStatementCount(pointer);
	}

	isCached(sql: string): boolean {
		return this.cache.has(sql);
	}

	private live(sql: string): Result<Ptr<sqlite3>, SqliteError> {
		const pointer = this.connection.pointer;
		if (pointer == null) return Result.err(misuse("the database is closed", sql));
		return Result.ok(pointer);
	}

	// Finalizes the cached statements and closes; WAL is checkpointed when this was the last
	// connection. A statement the caller still holds unfinalized makes it fail with Busy,
	// leaving the database open.
	close(): Result<void, SqliteError> {
		const pointer = this.connection.pointer;
		if (pointer == null) return Result.ok(null);
		for (const sql of this.cache) {
			const stmt = this.cache.get(sql);
			if (stmt != null) stmt.finalize();
		}
		this.cache.clear();
		this.stepping.clear();
		const rc = msqClose(pointer);
		if (rc != SQLITE_OK) return Result.err(this.connection.failure(rc, ""));
		this.connection.pointer = null;
		return Result.ok(null);
	}

	// Runs one or more `;`-separated statements that take no parameters.
	exec(sql: string): Result<void, SqliteError> {
		const pointer = try this.live(sql);
		const rc = msqExec(pointer, sql);
		if (rc != SQLITE_OK) return Result.err(this.connection.failure(rc, sql));
		return Result.ok(null);
	}

	private compile(sql: string, persistent: boolean): Result<Statement, SqliteError> {
		const pointer = try this.live(sql);
		let stmt: Ptr<sqlite3_stmt>;
		let tail: int32 = 0;
		const rc = msqPrepare(pointer, sql, persistent ? 1 : 0, out stmt, tail);
		if (rc != SQLITE_OK) return Result.err(this.connection.failure(rc, sql));
		if (stmt == null) return Result.err(misuse("the SQL holds no statement", sql));
		const prepared = new Statement(sql, new StatementHandle(stmt));
		if (sql.byteSlice(sql.byteLength() - tail, sql.byteLength()).trim() != "") {
			prepared.finalize();
			return Result.err(misuse("prepare takes one statement; exec runs several", sql));
		}
		return Result.ok(prepared);
	}

	// A new statement the caller owns; it is finalized when dropped or by finalize().
	prepare(sql: string): Result<Statement, SqliteError> {
		return this.compile(sql, false);
	}

	// The cached statement for `sql`, or a fresh one while the cached one is in use. The cache
	// keeps use order, so eviction takes the least recently used statement.
	private acquire(sql: string): Result<Statement, SqliteError> {
		const hit = this.cache.get(sql);
		if (hit != null && !this.stepping.has(sql)) {
			this.stepping.add(sql);
			this.cache.delete(sql);
			this.cache.set(sql, hit);
			return Result.ok(hit);
		}
		const stmt = try this.compile(sql, hit == null);
		if (hit != null || this.cacheSize <= 0) return Result.ok(stmt);
		if (this.cache.size >= this.cacheSize) this.evictOne();
		this.stepping.add(sql);
		this.cache.set(sql, stmt);
		return Result.ok(stmt);
	}

	private evictOne(): void {
		let oldest: string | null = null;
		for (const sql of this.cache) {
			if (!this.stepping.has(sql)) {
				oldest = sql;
				break;
			}
		}
		if (oldest == null) return;
		const stmt = this.cache.get(oldest);
		if (stmt != null) stmt.finalize();
		this.cache.delete(oldest);
	}

	private release(stmt: Statement): void {
		stmt.decodeFailure = null;
		if (this.cache.get(stmt.sql) != stmt) {
			stmt.finalize();
			return;
		}
		this.stepping.delete(stmt.sql);
		stmt.reset();
		stmt.clearBindings();
	}

	// Runs one statement to completion. Every query method takes either `Param` values bound in
	// order or `named(...)` values bound to the parameters of the same names.
	run(sql: string, params: Readonly<Span<Param>>): Result<RunResult, SqliteError> {
		return this.runWith<Readonly<Span<Param>>>(sql, params);
	}

	run(sql: string, params: Readonly<Named>): Result<RunResult, SqliteError> {
		return this.runWith<Readonly<Named>>(sql, params);
	}

	// Every row as JSON text (see rowsJson) for an endpoint that forwards rows unchanged.
	queryJson(sql: string, params: Readonly<Span<Param>>): Result<string, SqliteError> {
		return this.queryJsonWith<Readonly<Span<Param>>>(sql, params);
	}

	queryJson(sql: string, params: Readonly<Named>): Result<string, SqliteError> {
		return this.queryJsonWith<Readonly<Named>>(sql, params);
	}

	// Every row decoded into `T`: each field from the column of its name, with its storage
	// class and range checked; the first failed read fails the query.
	query<T>(sql: string, params: Readonly<Span<Param>>): Result<T[], SqliteError> {
		return this.queryWith<T, Readonly<Span<Param>>>(sql, params);
	}

	query<T>(sql: string, params: Readonly<Named>): Result<T[], SqliteError> {
		return this.queryWith<T, Readonly<Named>>(sql, params);
	}

	// The first row decoded into `T`, or null when there is none.
	queryOne<T>(sql: string, params: Readonly<Span<Param>>): Result<T | null, SqliteError> {
		return this.queryOneWith<T, Readonly<Span<Param>>>(sql, params);
	}

	queryOne<T>(sql: string, params: Readonly<Named>): Result<T | null, SqliteError> {
		return this.queryOneWith<T, Readonly<Named>>(sql, params);
	}

	// Decodes each row into `T` and hands it to `visit` without collecting them.
	each<T>(
		sql: string,
		params: Readonly<Span<Param>>,
		visit: (row: T) => void,
	): Result<int32, SqliteError> {
		return this.eachWith<T, Readonly<Span<Param>>>(sql, params, visit);
	}

	each<T>(
		sql: string,
		params: Readonly<Named>,
		visit: (row: T) => void,
	): Result<int32, SqliteError> {
		return this.eachWith<T, Readonly<Named>>(sql, params, visit);
	}

	// Acquires the statement for `sql`, binds `params` and hands it to `use`; the statement goes
	// back to the cache however `use` returns.
	private withStatement<P, R>(
		sql: string,
		params: P,
		use: (stmt: Statement) => Result<R, SqliteError>,
	): Result<R, SqliteError> {
		const stmt = try this.acquire(sql);
		defer this.release(stmt);
		try stmt.bindAll(params);
		return use(stmt);
	}

	// Decodes rows into `T` until `visit` returns false or the rows end; gives the rows visited.
	private decodeRows<T, P>(
		sql: string,
		params: P,
		visit: (row: T) => boolean,
	): Result<int32, SqliteError> {
		return this.withStatement<P, int32>(sql, params, (stmt) => {
			const columns = try stmt.columnIndexes(rowFields(null as T | null));
			let count: int32 = 0;
			while (try stmt.step()) {
				const row: T = rowDecode(stmt, columns, null as T | null);
				const failed = stmt.decodeFailure;
				if (failed != null) return Result.err(failed);
				count += 1;
				if (!visit(row)) break;
			}
			return Result.ok(count);
		});
	}

	private runWith<P>(sql: string, params: P): Result<RunResult, SqliteError> {
		const pointer = try this.live(sql);
		return this.withStatement<P, RunResult>(sql, params, (stmt) => {
			while (try stmt.step()) {}
			return Result.ok({
				changes: msqChanges(pointer),
				lastInsertRowid: msqLastInsertRowid(pointer),
			});
		});
	}

	private queryJsonWith<P>(sql: string, params: P): Result<string, SqliteError> {
		return this.withStatement<P, string>(sql, params, rowsJson);
	}

	private queryWith<T, P>(sql: string, params: P): Result<T[], SqliteError> {
		const rows: T[] = [];
		try this.decodeRows<T, P>(sql, params, (row) => {
			rows.push(row);
			return true;
		});
		return Result.ok(rows);
	}

	private queryOneWith<T, P>(sql: string, params: P): Result<T | null, SqliteError> {
		let found: T | null = null;
		try this.decodeRows<T, P>(sql, params, (row) => {
			found = row;
			return false;
		});
		return Result.ok(found);
	}

	private eachWith<T, P>(
		sql: string,
		params: P,
		visit: (row: T) => void,
	): Result<int32, SqliteError> {
		return this.decodeRows<T, P>(sql, params, (row) => {
			visit(row);
			return true;
		});
	}

	// Brings the schema to version `steps.length`: each step past PRAGMA user_version runs in its
	// own transaction together with recording its version, so a failed step leaves the version
	// of the last one that succeeded. A database newer than `steps`, or at a negative version,
	// is refused.
	migrate(steps: Readonly<Span<string>>): Result<int32, SqliteError> {
		const found = try this.queryOne<UserVersion>("PRAGMA user_version", []);
		const current = found == null ? 0 : found.user_version;
		if (current < 0 || current > steps.length) {
			return Result.err({
				code: ErrorCode.Schema,
				extended: SQLITE_SCHEMA,
				message: `the database is at schema version ${current}; ` +
					`this program knows ${steps.length} migrations`,
				sql: "",
			});
		}
		for (let version = current; version < steps.length; version++) {
			const sql = steps[version];
			const next = version + 1;
			try this.transaction<void, SqliteError>((): Result<void, SqliteError> => {
				try this.exec(sql);
				return this.exec(`PRAGMA user_version = ${next}`);
			}, (error: SqliteError): SqliteError => error);
		}
		return Result.ok(steps.length);
	}

	private undo(depth: int32): Result<void, SqliteError> {
		const pointer = this.connection.pointer;
		if (pointer == null || msqAutocommit(pointer) != 0) return Result.ok(null);
		if (depth == 0) {
			try this.run("ROLLBACK", []);
			return Result.ok(null);
		}
		try this.run(`ROLLBACK TO msq_${depth}`, []);
		try this.run(`RELEASE msq_${depth}`, []);
		return Result.ok(null);
	}

	// Runs `body` in a transaction: BEGIN IMMEDIATE at the outermost level, a SAVEPOINT inside
	// another. A failed or throwing body rolls back to where it began; `fromSqlite` turns a
	// failure to begin, commit or roll back into the body's error type. A failed rollback is
	// returned in place of the body's error, because it leaves the transaction open.
	transaction<T, E>(
		body: () => Result<T, E>,
		fromSqlite: (error: SqliteError) => E,
	): Result<T, E> {
		const depth = this.depth;
		const begin = this.run(depth == 0 ? "BEGIN IMMEDIATE" : `SAVEPOINT msq_${depth}`, []);
		if (!begin.ok) return Result.err(fromSqlite(begin.error));
		this.depth = depth + 1;
		let open = true;
		defer {
			if (open) {
				this.depth = depth;
				this.undo(depth);
			}
		}
		const result = body();
		open = false;
		this.depth = depth;
		if (!result.ok) {
			const undone = this.undo(depth);
			if (!undone.ok) return Result.err(fromSqlite(undone.error));
			return result;
		}
		const commit = this.run(depth == 0 ? "COMMIT" : `RELEASE msq_${depth}`, []);
		if (!commit.ok) {
			const undone = this.undo(depth);
			return Result.err(fromSqlite(undone.ok ? commit.error : undone.error));
		}
		return result;
	}
}

function memory(): Database {
	const opened = Database.open(":memory:");
	if (!opened.ok) throw new Error(opened.error.toString());
	return opened.value;
}

function scratchPath(name: string): string {
	return `/tmp/msqlite-${name}-${Date.now()}-${Math.floor(Math.random() * 1000000)}.db`;
}

struct Typed {
	i: int64;
	r: float64;
	t: string;
	b: uint8[];
	n: string | null;
}

struct Kinds {
	ti: string;
	tr: string;
	tt: string;
	tb: string;
	tn: string;
}

test "every parameter type binds with its exact storage class" {
	const db = memory();
	assert db.exec("CREATE TABLE v (i, r, t, b, n)").ok;
	const bytes: uint8[] = [0, 1, 255, 0];
	const big: int64 = 9223372036854775807;
	const ins = db.run("INSERT INTO v VALUES (?, ?, ?, ?, ?)", [
		integer(big), real(2.5), text("é🚀\nx"), blob(bytes), nullParam(),
	]);
	assert ins.ok && ins.value.changes == 1 && ins.value.lastInsertRowid == 1;
	const kinds = db.queryOne<Kinds>(
		"SELECT typeof(i) AS ti, typeof(r) AS tr, typeof(t) AS tt, typeof(b) AS tb, " +
			"typeof(n) AS tn FROM v",
		[],
	);
	assert kinds.ok && kinds.value != null;
	const k = kinds.value;
	assert k.ti == "integer" && k.tr == "real" && k.tt == "text";
	assert k.tb == "blob" && k.tn == "null";
	const rows = db.query<Typed>("SELECT i, r, t, b, n FROM v", []);
	assert rows.ok && rows.value.length == 1;
	const row = rows.value[0];
	assert row.i == big && row.r == 2.5 && row.t == "é🚀\nx" && row.n == null;
	assert row.b.length == 4 && row.b[0] == 0 && row.b[2] == 255 && row.b[3] == 0;
	assert db.close().ok;
}

struct Sample {
	host: string;
	busy: float64;
	cores: int32;
	up: boolean;
	note: string | null;
}

struct HostBusy {
	host: string;
	busy: float64;
}

test "named values bind each field to the parameter of its name, by any prefix" {
	const db = memory();
	const create = "CREATE TABLE s (host TEXT, busy REAL, cores INTEGER, up INTEGER, note TEXT)";
	assert db.exec(create).ok;
	const s: Sample = { host: "web-1", busy: 0.25, cores: 8, up: true, note: null };
	const ins = db.run("INSERT INTO s VALUES (:host, @busy, $cores, :up, :note)", named(s));
	assert ins.ok && ins.value.changes == 1;
	const rows = db.query<Sample>("SELECT * FROM s WHERE host = :host", named({ host: "web-1" }));
	assert rows.ok && rows.value.length == 1;
	const row = rows.value[0];
	assert row.host == "web-1" && row.busy == 0.25 && row.cores == 8 && row.up && row.note == null;
	const one = db.queryOne<HostBusy>(
		"SELECT host, busy FROM s WHERE busy < :limit AND cores >= :cores",
		named({ limit: 0.5, cores: 4 }),
	);
	assert one.ok && one.value != null && one.value.host == "web-1";
	assert db.close().ok;
}

test "a parameter without a value, a value without a parameter and a ? marker are refused" {
	const db = memory();
	assert db.exec("CREATE TABLE s (host TEXT, busy REAL)").ok;
	const missing = db.run("INSERT INTO s VALUES (:host, :busy)", named({ host: "a" }));
	assert !missing.ok && missing.error.code == ErrorCode.Range;
	assert missing.error.message == "no value for parameter :busy";
	const extra = db.run("INSERT INTO s VALUES (:host, 1)", named({ host: "a", busy: 2.0 }));
	assert !extra.ok && extra.error.message == "the statement has no parameter for \"busy\"";
	const positional = db.run("INSERT INTO s VALUES (?, :busy)", named({ busy: 2.0 }));
	assert !positional.ok && positional.error.code == ErrorCode.Range;
	assert countOf(db, "SELECT count(*) AS n FROM s") == 0;
	const reused = db.run("INSERT INTO s VALUES (:host, :busy)", named({ host: "b", busy: 1.0 }));
	assert reused.ok && countOf(db, "SELECT count(*) AS n FROM s") == 1;
	assert db.close().ok;
}

struct CompileOption {
	compile_options: string;
}

test "the amalgamation is built with its flags" {
	const db = memory();
	const options = db.query<CompileOption>("PRAGMA compile_options", []);
	assert options.ok;
	const names = options.value.map((o: CompileOption): string => o.compile_options);
	for (const wanted of ["DQS=0", "ENABLE_FTS5", "OMIT_LOAD_EXTENSION", "DEFAULT_FOREIGN_KEYS"]) {
		assert names.includes(wanted);
	}
	assert db.close().ok;
}

test "foreign keys are enforced unless the connection turns them off" {
	const db = memory();
	assert db.exec("CREATE TABLE host (name TEXT PRIMARY KEY); " +
		"CREATE TABLE pick (host TEXT REFERENCES host (name))").ok;
	const orphan = db.run("INSERT INTO pick VALUES (?)", [text("nowhere")]);
	assert !orphan.ok && orphan.error.code == ErrorCode.Constraint;
	assert db.exec("PRAGMA foreign_keys = OFF").ok;
	assert db.run("INSERT INTO pick VALUES (?)", [text("nowhere")]).ok;
	assert db.close().ok;
}

test "migrate runs each step past the recorded version once" {
	const db = memory();
	const steps = ["CREATE TABLE a (x)", "CREATE TABLE b (y)"];
	const first = db.migrate(steps);
	assert first.ok && first.value == 2;
	assert db.migrate(steps).ok;
	const grown = db.migrate([...steps, "ALTER TABLE a ADD COLUMN z"]);
	assert grown.ok && grown.value == 3;
	assert db.run("INSERT INTO a (x, z) VALUES (1, 2)", []).ok;
	assert db.close().ok;
}

test "a failed step keeps the last good version and a newer database is refused" {
	const db = memory();
	const failed = db.migrate(["CREATE TABLE a (x)", "CREATE TABLE b (y); CREATE TABLE a (x)"]);
	assert !failed.ok;
	assert countOf(db, "SELECT count(*) AS n FROM sqlite_schema WHERE name = 'b'") == 0;
	assert countOf(db, "SELECT user_version AS n FROM pragma_user_version") == 1;
	assert db.exec("PRAGMA user_version = 5").ok;
	const newer = db.migrate(["CREATE TABLE c (z)"]);
	assert !newer.ok && newer.error.code == ErrorCode.Schema;
	assert db.close().ok;
}

test "a negative schema version is refused, not used as a step index" {
	const db = memory();
	assert db.exec("PRAGMA user_version = -1").ok;
	const negative = db.migrate(["CREATE TABLE a (x)"]);
	assert !negative.ok && negative.error.code == ErrorCode.Schema;
	assert countOf(db, "SELECT count(*) AS n FROM sqlite_schema") == 0;
	assert db.close().ok;
}

test "an empty text and an empty blob bind as values, not NULL" {
	const db = memory();
	const empty: uint8[] = [];
	const kinds = db.queryOne<Kinds>(
		"SELECT typeof(?1) AS ti, typeof(?2) AS tr, typeof(?1) AS tt, typeof(?2) AS tb, " +
			"typeof(?3) AS tn",
		[text(""), blob(empty), maybe<int64>(null, integer)],
	);
	assert kinds.ok && kinds.value != null;
	assert kinds.value.ti == "text" && kinds.value.tr == "blob" && kinds.value.tn == "null";
}

struct Narrow {
	small: int8;
	count: int32;
	flag: boolean;
	ratio: float64;
	label: string | null;
}

test "a decoded row reads every supported field type" {
	const db = memory();
	const rows = db.query<Narrow>(
		"SELECT -128 AS small, 2147483647 AS count, 1 AS flag, 7 AS ratio, NULL AS label " +
			"UNION ALL SELECT 127, -2147483648, 0, 0.25, 'x'",
		[],
	);
	assert rows.ok && rows.value.length == 2;
	const a = rows.value[0];
	const b = rows.value[1];
	assert a.small == -128 && a.count == 2147483647 && a.flag && a.ratio == 7 && a.label == null;
	assert b.small == 127 && b.count == -2147483648 && !b.flag && b.ratio == 0.25 && b.label == "x";
}

function decodeError(sql: string): ErrorCode | null {
	const db = memory();
	const r = db.query<Narrow>(sql, []);
	return r.ok ? null : r.error.code;
}

test "a missing column is refused, naming the field and the columns" {
	const db = memory();
	const r = db.query<Narrow>("SELECT 1 AS small, 2 AS count, 1 AS flag, 1.0 AS ratio", []);
	assert !r.ok && r.error.code == ErrorCode.MissingColumn;
	assert r.error.message.contains("label");
	assert r.error.message.contains("small, count, flag, ratio");
}

test "a column of the wrong storage class is refused, NULL included" {
	assert decodeError("SELECT 'x' AS small, 2 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label") ==
		ErrorCode.WrongKind;
	assert decodeError("SELECT 1 AS small, 2.5 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label") ==
		ErrorCode.WrongKind;
	assert decodeError(
		"SELECT 1 AS small, NULL AS count, 1 AS flag, 1.0 AS ratio, NULL AS label",
	) == ErrorCode.WrongKind;
	assert decodeError("SELECT 1 AS small, 2 AS count, 1 AS flag, 'x' AS ratio, NULL AS label") ==
		ErrorCode.WrongKind;
	assert decodeError("SELECT 1 AS small, 2 AS count, 1 AS flag, 1.0 AS ratio, 3 AS label") ==
		ErrorCode.WrongKind;
}

test "an integer outside its field's range is refused, not wrapped" {
	assert decodeError("SELECT 128 AS small, 2 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label") ==
		ErrorCode.OutOfRange;
	assert decodeError(
		"SELECT 1 AS small, 2147483648 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label",
	) == ErrorCode.OutOfRange;
	assert decodeError("SELECT 1 AS small, 2 AS count, 2 AS flag, 1.0 AS ratio, NULL AS label") ==
		ErrorCode.OutOfRange;
	assert decodeError(
		"SELECT 1 AS small, 2 AS count, 1 AS flag, 9007199254740993 AS ratio, NULL AS label",
	) == ErrorCode.OutOfRange;
	const db = memory();
	const r = db.query<Narrow>(
		"SELECT 1 AS small, 2147483648 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label",
		[],
	);
	assert !r.ok && r.error.message.contains("2147483648") && r.error.message.contains("count");
}

test "the first failed row fails the query and the statement stays usable" {
	const db = memory();
	const sql = "SELECT value AS small, 1 AS count, 1 AS flag, 1.0 AS ratio, NULL AS label FROM " +
		"(SELECT 1 AS value UNION ALL SELECT 999)";
	const r = db.query<Narrow>(sql, []);
	assert !r.ok && r.error.code == ErrorCode.OutOfRange;
	const again = db.query<Narrow>(sql + " WHERE value < 100", []);
	assert again.ok && again.value.length == 1;
}

struct Count { n: int64; }

test "queryOne gives null for no row and the first row otherwise" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	const none = db.queryOne<Count>("SELECT n FROM t", []);
	assert none.ok && none.value == null;
	assert db.run("INSERT INTO t VALUES (?), (?)", [integer(4), integer(5)]).ok;
	const first = db.queryOne<Count>("SELECT n FROM t ORDER BY n", []);
	assert first.ok && first.value != null && first.value.n == 4;
}

test "each visits rows without collecting them" {
	const db = memory();
	let total: int64 = 0;
	const sql = "SELECT value AS n FROM json_each('[1,2,3]')";
	const r = db.each<Count>(sql, [], (row: Count): void => {
		total += row.n;
	});
	assert r.ok && r.value == 3 && total == 6;
}

function countOf(db: Database, sql: string): int64 {
	const r = db.queryOne<Count>(sql, []);
	if (!r.ok || r.value == null) return -1;
	return r.value.n;
}

function sqliteMessage(error: SqliteError): string {
	return error.toString();
}

test "a transaction commits a successful body and rolls back a failed one" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	const kept = db.transaction((): Result<int32, string> => {
		if (!db.run("INSERT INTO t VALUES (1)", []).ok) return Result.err("insert");
		return Result.ok(7);
	}, sqliteMessage);
	assert kept.ok && kept.value == 7;
	const dropped = db.transaction((): Result<int32, string> => {
		if (!db.run("INSERT INTO t VALUES (2)", []).ok) return Result.err("insert");
		return Result.err("stop");
	}, sqliteMessage);
	assert !dropped.ok && dropped.error == "stop";
	assert countOf(db, "SELECT COUNT(*) AS n FROM t") == 1;
}

test "a nested transaction is a savepoint: its rollback keeps the outer work" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	const outer = db.transaction((): Result<void, string> => {
		if (!db.run("INSERT INTO t VALUES (1)", []).ok) return Result.err("outer insert");
		const inner = db.transaction((): Result<void, string> => {
			if (!db.run("INSERT INTO t VALUES (2)", []).ok) return Result.err("inner insert");
			return Result.err("inner stops");
		}, sqliteMessage);
		if (inner.ok) return Result.err("the inner body should have failed");
		const deeper = db.transaction((): Result<void, string> => {
			if (!db.run("INSERT INTO t VALUES (3)", []).ok) return Result.err("deeper insert");
			return Result.ok(null);
		}, sqliteMessage);
		return deeper;
	}, sqliteMessage);
	assert outer.ok;
	assert countOf(db, "SELECT COUNT(*) AS n FROM t") == 2;
	assert countOf(db, "SELECT SUM(n) AS n FROM t") == 4;
}

test "a rollback that fails is the error the transaction returns" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	const outer = db.transaction((): Result<void, string> => {
		const inner = db.transaction((): Result<void, string> => {
			if (!db.exec("RELEASE msq_1").ok) return Result.err("release");
			return Result.err("inner stops");
		}, sqliteMessage);
		if (inner.ok) return Result.err("the inner body should have failed");
		return Result.err(inner.error);
	}, sqliteMessage);
	assert !outer.ok && outer.error.contains("no such savepoint: msq_1");
	assert outer.error.contains("ROLLBACK TO msq_1");
	const next = db.transaction((): Result<void, string> => Result.ok(null), sqliteMessage);
	assert next.ok;
}

test "a throwing body rolls back and leaves no transaction open" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	let caught = false;
	try {
		db.transaction((): Result<void, string> => {
			db.run("INSERT INTO t VALUES (1)", []);
			throw new Error("boom");
		}, sqliteMessage);
	} catch (e) {
		caught = true;
	}
	assert caught;
	assert countOf(db, "SELECT COUNT(*) AS n FROM t") == 0;
	const next = db.transaction((): Result<void, string> => Result.ok(null), sqliteMessage);
	assert next.ok;
}

test "the statement cache reuses one statement per SQL text" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n INTEGER)").ok;
	for (let i: int32 = 0; i < 10; i++) assert db.run("INSERT INTO t VALUES (?)", [integer(i)]).ok;
	assert db.openStatements() == 1;
	assert countOf(db, "SELECT COUNT(*) AS n FROM t") == 10;
	assert db.openStatements() == 2;
}

test "the cache evicts its oldest statement past its size" {
	const options: OpenOptions = { ...DEFAULT_OPEN_OPTIONS, statementCacheSize: 2 };
	const opened = Database.open(":memory:", options);
	assert opened.ok;
	const db = opened.value;
	assert countOf(db, "SELECT 1 AS n") == 1;
	assert countOf(db, "SELECT 2 AS n") == 2;
	assert countOf(db, "SELECT 3 AS n") == 3;
	assert db.openStatements() == 2;
}

test "a cache hit keeps its statement past one that was used less recently" {
	const options: OpenOptions = { ...DEFAULT_OPEN_OPTIONS, statementCacheSize: 2 };
	const opened = Database.open(":memory:", options);
	assert opened.ok;
	const db = opened.value;
	assert countOf(db, "SELECT 1 AS n") == 1;
	assert countOf(db, "SELECT 2 AS n") == 2;
	assert countOf(db, "SELECT 1 AS n") == 1;
	assert countOf(db, "SELECT 3 AS n") == 3;
	assert db.isCached("SELECT 1 AS n") && !db.isCached("SELECT 2 AS n");
}

test "the same SQL run while its cached statement is stepping gets its own statement" {
	const db = memory();
	const sql = "SELECT value AS n FROM json_each(?)";
	let inner: int64 = 0;
	const r = db.each<Count>(sql, [text("[1,2]")], (row: Count): void => {
		const nested = db.query<Count>(sql, [text("[10,20]")]);
		if (nested.ok) for (const c of nested.value) inner += c.n * row.n;
	});
	assert r.ok && r.value == 2 && inner == 90;
	assert db.openStatements() == 1;
}

test "close finalizes cached statements; later calls fail with Misuse" {
	const db = memory();
	assert countOf(db, "SELECT 1 AS n") == 1;
	assert db.close().ok;
	assert !db.isOpen;
	assert db.close().ok;
	const after = db.run("SELECT 1", []);
	assert !after.ok && after.error.code == ErrorCode.Misuse;
	const exec = db.exec("SELECT 1");
	assert !exec.ok && exec.error.code == ErrorCode.Misuse;
}

test "close refuses while the caller holds an unfinalized statement" {
	const db = memory();
	const stmt = db.prepare("SELECT 1");
	assert stmt.ok;
	const refused = db.close();
	assert !refused.ok && refused.error.code == ErrorCode.Busy && db.isOpen;
	stmt.value.finalize();
	assert stmt.value.isFinalized;
	const stepped = stmt.value.step();
	assert !stepped.ok && stepped.error.code == ErrorCode.Misuse;
	assert db.close().ok;
}

test "a dropped database closes itself: its WAL file is checkpointed away" {
	const path = scratchPath("drop");
	{
		const opened = Database.open(path);
		assert opened.ok;
		const db = opened.value;
		const alias = db;
		const setup = "PRAGMA journal_mode = WAL; CREATE TABLE t (n); INSERT INTO t VALUES (1)";
		assert db.exec(setup).ok;
		assert alias.isOpen && exists(`${path}-wal`);
	}
	assert !exists(`${path}-wal`);
	const reopened = Database.open(path);
	assert reopened.ok && countOf(reopened.value, "SELECT COUNT(*) AS n FROM t") == 1;
	assert reopened.value.close().ok;
	remove(path);
}

test "an explicit close checkpoints the WAL file" {
	const path = scratchPath("close");
	const opened = Database.open(path);
	assert opened.ok;
	const db = opened.value;
	assert db.exec("PRAGMA journal_mode = WAL; CREATE TABLE t (n); INSERT INTO t VALUES (1)").ok;
	assert exists(`${path}-wal`);
	assert db.close().ok;
	assert !exists(`${path}-wal`);
	remove(path);
}

test "sqlite's result code reaches the error as its case, with message and SQL" {
	const db = memory();
	assert db.exec("CREATE TABLE u (k TEXT UNIQUE)").ok;
	assert db.run("INSERT INTO u VALUES (?)", [text("a")]).ok;
	const dup = db.run("INSERT INTO u VALUES (?)", [text("a")]);
	assert !dup.ok && dup.error.code == ErrorCode.Constraint && dup.error.extended == 2067;
	assert dup.error.message.contains("UNIQUE constraint failed: u.k");
	assert dup.error.sql == "INSERT INTO u VALUES (?)";
	const bad = db.run("SELEC 1", []);
	assert !bad.ok && bad.error.code == ErrorCode.Generic;
	assert bad.error.message.contains("syntax error");
	const missing = db.exec("INSERT INTO nowhere VALUES (1)");
	assert !missing.ok && missing.error.message.contains("no such table: nowhere");
}

test "a failed open carries sqlite's own error" {
	const options: OpenOptions = { ...DEFAULT_OPEN_OPTIONS, mode: OpenMode.ReadWrite };
	const r = Database.open("/nonexistent-dir/x.db", options);
	assert !r.ok && r.error.code == ErrorCode.CantOpen;
	assert r.error.message.contains("unable to open database file");
	assert r.error.message.contains("/nonexistent-dir/x.db");
}

test "a write lock held by another connection is Busy once the timeout passes" {
	const path = scratchPath("busy");
	const options: OpenOptions = { ...DEFAULT_OPEN_OPTIONS, busyTimeoutMs: 0 };
	const a = Database.open(path, options);
	const b = Database.open(path, options);
	assert a.ok && b.ok;
	assert a.value.exec("CREATE TABLE t (n); BEGIN IMMEDIATE").ok;
	const blocked = b.value.exec("BEGIN IMMEDIATE");
	assert !blocked.ok && blocked.error.code == ErrorCode.Busy;
	assert a.value.exec("COMMIT").ok;
	assert a.value.close().ok && b.value.close().ok;
	remove(path);
}

test "a parameter count that does not match the statement is refused" {
	const db = memory();
	const few = db.run("SELECT ?, ?", [integer(1)]);
	assert !few.ok && few.error.code == ErrorCode.Range;
	const many = db.run("SELECT ?", [integer(1), integer(2)]);
	assert !many.ok && many.error.code == ErrorCode.Range;
}

test "prepare takes one statement; exec runs several" {
	const db = memory();
	const two = db.prepare("CREATE TABLE a (n); CREATE TABLE b (n)");
	assert !two.ok && two.error.code == ErrorCode.Misuse;
	assert db.openStatements() == 0;
	assert db.exec("CREATE TABLE a (n); CREATE TABLE b (n); INSERT INTO b VALUES (1)").ok;
	assert countOf(db, "SELECT COUNT(*) AS n FROM b") == 1;
	const trailing = db.prepare("SELECT 1;  ");
	assert trailing.ok;
}

test "a second statement after multi-byte text is refused, not dropped" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	const sql = "SELECT '" + "🚀".repeat(20) + "'; DROP TABLE t";
	const prepared = db.prepare(sql);
	assert !prepared.ok && prepared.error.code == ErrorCode.Misuse;
	const ran = db.run(sql, []);
	assert !ran.ok && ran.error.code == ErrorCode.Misuse;
	assert countOf(db, "SELECT count(*) AS n FROM t") == 0;
}

test "a prepared statement binds, steps, resets and reads columns" {
	const db = memory();
	const prepared = db.prepare("SELECT ?1 + 1 AS next, typeof(?1) AS kind");
	assert prepared.ok;
	const stmt = prepared.value;
	assert stmt.parameterCount() == 1 && stmt.columnCount() == 2 && stmt.columnName(0) == "next";
	assert stmt.bind(1, integer(41)).ok;
	const first = stmt.step();
	assert first.ok && first.value;
	assert stmt.columnKind(0) == ColumnKind.Integer;
	const next = stmt.integerAt(0);
	assert next.ok && next.value == 42;
	const asText = stmt.textAt(0);
	assert !asText.ok && asText.error.code == ErrorCode.WrongKind;
	const done = stmt.step();
	assert done.ok && !done.value;
	stmt.reset();
	assert stmt.bind(1, real(1.5)).ok;
	assert stmt.step().ok;
	const r = stmt.realAt(0);
	assert r.ok && r.value == 2.5;
	stmt.finalize();
}

test "rows forward as JSON with every storage class encoded" {
	const db = memory();
	const r = db.queryJson(
		"SELECT 9007199254740993 AS i, 0.1 AS r, 'q\"\\\n\t' || char(1) AS t, x'4d61' AS b, " +
			"NULL AS n, 1e999 AS inf, -1e999 AS ninf, ? AS p",
		[text("é🚀")],
	);
	assert r.ok;
	assert r.value == "[{\"i\":9007199254740993,\"r\":0.1," +
		"\"t\":\"q\\\"\\\\\\n\\t\\u0001\",\"b\":\"TWE=\"," +
		"\"n\":null,\"inf\":null,\"ninf\":null,\"p\":\"é🚀\"}]";
	const empty = db.queryJson("SELECT 1 AS a WHERE 0", []);
	assert empty.ok && empty.value == "[]";
	const parsed = JSON.parseValue(r.value);
	assert parsed.ok;
}

test "text holding a NUL byte is refused rather than cut short" {
	const db = memory();
	const json = db.queryJson("SELECT 'a' || char(0) || 'b' AS t", []);
	assert !json.ok && json.error.code == ErrorCode.OutOfRange;
	struct Text { t: string; }
	const typed = db.query<Text>("SELECT 'a' || char(0) || 'b' AS t", []);
	assert !typed.ok && typed.error.code == ErrorCode.OutOfRange;
}
