// Adversarial edges of the driver: integer and text boundaries, storage-class mismatches,
// misuse after close, transaction failure paths, the statement cache and native lifetimes.
import { Database, ErrorCode, Param, SqliteError, Statement, named } from "../src/index";
import { Connection } from "../src/native";
import { msqOpen, sqlite3 } from "../src/native/sqlite.h";

@include("../vendor/sqlite3/sqlite3.h");
extern function sqliteLimit(
	db: Ptr<sqlite3>,
	limit: int32,
	value: int32,
): int32 from "sqlite3_limit";

const SQLITE_LIMIT_SQL_LENGTH: int32 = 1;
const OPEN_READWRITE_CREATE: int32 = 6;

function memory(): Database {
	const opened = Database.open(":memory:");
	if (!opened.ok) throw new Error(opened.error.toString());
	return opened.value;
}

function message(error: SqliteError): string {
	return error.toString();
}

struct Wide { n: int64; }
struct Small { n: int32; }
struct Byte { n: uint8; }
struct Unsigned { n: uint32; }
struct Short { n: int16; }
struct Real { n: float64; }
struct MaybeReal { n: float64 | null; }
struct Words { s: string; }
struct MaybeWords { s: string | null; }
struct Bytes { b: uint8[]; }
struct Kind { k: string; }
struct Count { n: int64; }

function count(db: Database, sql: string): int64 {
	const r = db.get<Count>(sql);
	if (!r.ok || r.value == null) return -1;
	return r.value!.n;
}

// Integer boundaries

test "int64 max and min round-trip through a bound parameter" {
	const db = memory();
	const max: int64 = 9223372036854775807;
	const min: int64 = -9223372036854775807 - 1;
	const r = db.all<Wide>(
		"SELECT ? AS n UNION ALL SELECT ?",
		[Param.integer(max), Param.integer(min)],
	);
	assert r.ok && r.value.length == 2;
	assert r.value[0].n == max && r.value[1].n == min;
}

test "int64 min written as a SQL literal decodes exactly" {
	const db = memory();
	const r = db.get<Wide>("SELECT -9223372036854775808 AS n");
	assert r.ok && r.value != null && r.value!.n == -9223372036854775807 - 1;
}

test "int64 max and min forward to JSON as exact decimals" {
	const db = memory();
	const max: int64 = 9223372036854775807;
	const min: int64 = -9223372036854775807 - 1;
	const r = db.allJson("SELECT ? AS a, ? AS b", [Param.integer(max), Param.integer(min)]);
	assert r.ok && r.value == "[{\"a\":9223372036854775807,\"b\":-9223372036854775808}]";
}

test "an int64 past int32 into an int32 field is OutOfRange, not wrapped" {
	const db = memory();
	const r = db.all<Small>("SELECT 4294967297 AS n");
	assert !r.ok && r.error.code == ErrorCode.OutOfRange;
	assert r.error.message.contains("4294967297");
}

test "int32 bounds decode exactly at both ends" {
	const db = memory();
	const r = db.all<Small>("SELECT 2147483647 AS n UNION ALL SELECT -2147483648");
	assert r.ok && r.value[0].n == 2147483647 && r.value[1].n == -2147483648;
}

test "256 and -1 into a uint8 field are OutOfRange; 0 and 255 decode" {
	const db = memory();
	const high = db.all<Byte>("SELECT 256 AS n");
	assert !high.ok && high.error.code == ErrorCode.OutOfRange;
	const low = db.all<Byte>("SELECT -1 AS n");
	assert !low.ok && low.error.code == ErrorCode.OutOfRange;
	const ok = db.all<Byte>("SELECT 0 AS n UNION ALL SELECT 255");
	assert ok.ok && ok.value[0].n == 0 && ok.value[1].n == 255;
}

test "-1 into a uint32 field is OutOfRange; 4294967295 decodes" {
	const db = memory();
	const neg = db.all<Unsigned>("SELECT -1 AS n");
	assert !neg.ok && neg.error.code == ErrorCode.OutOfRange;
	const max = db.get<Unsigned>("SELECT 4294967295 AS n");
	assert max.ok && max.value != null && max.value!.n == 4294967295;
}

test "32768 into an int16 field is OutOfRange" {
	const db = memory();
	const r = db.all<Short>("SELECT 32768 AS n");
	assert !r.ok && r.error.code == ErrorCode.OutOfRange;
}

test "a REAL holding a whole number into an integer field is WrongKind" {
	const db = memory();
	const r = db.all<Small>("SELECT 3.0 AS n");
	assert !r.ok && r.error.code == ErrorCode.WrongKind;
	const wide = db.all<Wide>("SELECT 3.0 AS n");
	assert !wide.ok && wide.error.code == ErrorCode.WrongKind;
}

test "Infinity binds as REAL and round-trips" {
	const db = memory();
	const kind = db.get<Kind>("SELECT typeof(?) AS k", [Param.real(Infinity)]);
	assert kind.ok && kind.value != null && kind.value!.k == "real";
	const r = db.get<Real>("SELECT ? AS n", [Param.real(-Infinity)]);
	assert r.ok && r.value != null && r.value!.n == -Infinity;
}

test "NaN is refused, because SQLite would store it as NULL" {
	const db = memory();
	const kind = db.get<Kind>("SELECT typeof(?) AS k", [Param.real(NaN)]);
	assert !kind.ok && kind.error.code == ErrorCode.Range && kind.error.message.contains("NaN");
	assert db.exec("CREATE TABLE f (n REAL)").ok;
	const insert = db.run("INSERT INTO f VALUES (?)", [Param.real(NaN)]);
	assert !insert.ok && insert.error.code == ErrorCode.Range;
	assert count(db, "SELECT count(*) AS n FROM f") == 0;
}

test "a non-finite REAL forwards to JSON as null" {
	const db = memory();
	const r = db.allJson("SELECT ? AS a, ? AS b", [Param.real(Infinity), Param.real(-Infinity)]);
	assert r.ok && r.value == "[{\"a\":null,\"b\":null}]";
}

test "extreme finite REALs forward as JSON numbers that parse back" {
	const db = memory();
	const r = db.allJson(
		"SELECT 1e300 AS a, 5e-324 AS b, -0.0 AS c, 123456789.125 AS d, 1e21 AS e",
	);
	assert r.ok;
	const parsed = JSON.parseValue(r.value);
	assert parsed.ok, r.value;
}

// Text

test "an empty string round-trips as TEXT, not NULL" {
	const db = memory();
	const r = db.get<Words>("SELECT ? AS s", [Param.text("")]);
	assert r.ok && r.value != null && r.value!.s == "";
}

test "text bound with an embedded NUL is refused on read, not cut short" {
	const db = memory();
	const withNul = "a" + String.fromCharCode(0) + "b";
	assert withNul.byteLength() == 3;
	const len = db.get<Count>("SELECT length(CAST(? AS BLOB)) AS n", [Param.text(withNul)]);
	assert len.ok && len.value != null && len.value!.n == 3;
	const r = db.all<Words>("SELECT ? AS s", [Param.text(withNul)]);
	assert !r.ok && r.error.code == ErrorCode.OutOfRange;
}

test "emoji and Vietnamese text round-trip byte-exact and count as characters in SQL" {
	const db = memory();
	const s = "Tiếng Việt có dấu 🚀👩‍👩‍👧";
	const r = db.get<Words>("SELECT ? AS s", [Param.text(s)]);
	assert r.ok && r.value != null && r.value!.s == s;
	const bytes = db.get<Count>("SELECT length(CAST(? AS BLOB)) AS n", [Param.text(s)]);
	assert bytes.ok && bytes.value != null && bytes.value!.n == s.byteLength() as int64;
	const literal = db.get<Words>("SELECT 'Việt 🚀' AS s");
	assert literal.ok && literal.value != null && literal.value!.s == "Việt 🚀";
}

test "1 MB of text round-trips" {
	const db = memory();
	const big = "ệ".repeat(349526);
	assert db.exec("CREATE TABLE t (s TEXT)").ok;
	assert db.run("INSERT INTO t VALUES (?)", [Param.text(big)]).ok;
	const r = db.get<Words>("SELECT s FROM t");
	assert r.ok && r.value != null && r.value!.s == big;
}

test "a BLOB into a string field is WrongKind" {
	const db = memory();
	const r = db.all<Words>("SELECT x'4142' AS s");
	assert !r.ok && r.error.code == ErrorCode.WrongKind;
}

test "a TEXT into a uint8[] field is WrongKind" {
	const db = memory();
	const r = db.all<Bytes>("SELECT 'AB' AS b");
	assert !r.ok && r.error.code == ErrorCode.WrongKind;
}

test "an INTEGER into a string field is WrongKind, not formatted" {
	const db = memory();
	const r = db.all<Words>("SELECT 42 AS s");
	assert !r.ok && r.error.code == ErrorCode.WrongKind;
}

// Blob

test "an empty blob round-trips as a zero-length BLOB" {
	const db = memory();
	const empty: uint8[] = [];
	const r = db.get<Bytes>("SELECT ? AS b", [Param.blob(empty)]);
	assert r.ok && r.value != null && r.value!.b.length == 0;
	const json = db.allJson("SELECT ? AS b", [Param.blob(empty)]);
	assert json.ok && json.value == "[{\"b\":\"\"}]";
}

function pattern(length: int32): uint8[] {
	const bytes = new Array<uint8>(length);
	for (let i: int32 = 0; i < length; i++) bytes[i] = (i * 31 + 7) as uint8;
	return bytes;
}

test "a 1 MB blob round-trips byte-exact" {
	const db = memory();
	const bytes = pattern(1048576);
	assert db.exec("CREATE TABLE b (v BLOB)").ok;
	assert db.run("INSERT INTO b VALUES (?)", [Param.blob(bytes)]).ok;
	const r = db.get<Bytes>("SELECT v AS b FROM b");
	assert r.ok && r.value != null;
	const back = r.value!.b;
	assert back.length == bytes.length;
	let same = true;
	for (let i: int32 = 0; i < back.length; i++) {
		if (back[i] != bytes[i]) {
			same = false;
			break;
		}
	}
	assert same;
}

test "allJson encodes a 1 MB blob as base64 of the right length" {
	const db = memory();
	const bytes = pattern(1048576);
	const r = db.allJson("SELECT ? AS b", [Param.blob(bytes)]);
	assert r.ok;
	// 1048576 bytes → 349526 groups → 1398104 base64 chars, plus `[{"b":""}]`.
	assert r.value.length == 1398104 + 10;
	assert r.value.startsWith("[{\"b\":\"ByZF") && r.value.endsWith("==\"}]");
}

test "allJson base64 matches sqlite's own hex for one to three bytes" {
	const db = memory();
	const r = db.allJson("SELECT x'ff' AS a, x'fffe' AS b, x'fffefd' AS c, x'00' AS d");
	assert r.ok && r.value == "[{\"a\":\"/w==\",\"b\":\"//4=\",\"c\":\"//79\",\"d\":\"AA==\"}]";
}

// Null

test "NULL into a non-nullable field is WrongKind" {
	const db = memory();
	const ints = db.all<Small>("SELECT NULL AS n");
	assert !ints.ok && ints.error.code == ErrorCode.WrongKind;
	const words = db.all<Words>("SELECT ? AS s", [Param.null()]);
	assert !words.ok && words.error.code == ErrorCode.WrongKind;
	const bytes = db.all<Bytes>("SELECT NULL AS b");
	assert !bytes.ok && bytes.error.code == ErrorCode.WrongKind;
}

test "NULL into a T | null field decodes as null" {
	const db = memory();
	const r = db.get<MaybeWords>("SELECT NULL AS s");
	assert r.ok && r.value != null && r.value!.s == null;
	const real = db.get<MaybeReal>("SELECT NULL AS n");
	assert real.ok && real.value != null && real.value!.n == null;
}

test "a T | null field still checks the storage class of a non-NULL value" {
	const db = memory();
	const r = db.all<MaybeWords>("SELECT 7 AS s");
	assert !r.ok && r.error.code == ErrorCode.WrongKind;
}

// Misuse

test "every call after close() fails with Misuse" {
	const db = memory();
	assert db.close().ok;
	const prepared = db.prepare("SELECT 1");
	assert !prepared.ok && prepared.error.code == ErrorCode.Misuse;
	const q = db.all<Small>("SELECT 1 AS n");
	assert !q.ok && q.error.code == ErrorCode.Misuse;
	const one = db.get<Small>("SELECT 1 AS n");
	assert !one.ok && one.error.code == ErrorCode.Misuse;
	const json = db.allJson("SELECT 1 AS n");
	assert !json.ok && json.error.code == ErrorCode.Misuse;
	let visited = 0;
	const each = db.iterate<Small>("SELECT 1 AS n", (row: Small): void => {
		visited += 1;
	});
	assert !each.ok && each.error.code == ErrorCode.Misuse && visited == 0;
	const migrated = db.migrate(["CREATE TABLE a (x)"]);
	assert !migrated.ok && migrated.error.code == ErrorCode.Misuse;
	const tx = db.transaction((): Result<void, string> => Result.ok(null), message);
	assert !tx.ok;
	assert db.openStatements() == 0 && !db.isOpen;
}

test "close() while a prepared Statement is held fails Busy and the db stays usable" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	assert db.run("INSERT INTO t VALUES (?)", [Param.integer(1)]).ok;
	const held = db.prepare("SELECT n FROM t");
	assert held.ok;
	const refused = db.close();
	assert !refused.ok && refused.error.code == ErrorCode.Busy && db.isOpen;
	assert db.run("INSERT INTO t VALUES (?)", [Param.integer(2)]).ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 2;
	const stmt = held.value;
	const stepped = stmt.step();
	assert stepped.ok && stepped.value;
	held.value.finalize();
	assert db.close().ok;
}

test "close() inside an iterate visitor does not pull the stepping statement away" {
	const db = memory();
	let closed: boolean | null = null;
	let visits = 0;
	const sql = "SELECT value AS n FROM json_each('[1,2,3]')";
	const r = db.iterate<Count>(sql, (row: Count): void => {
		visits += 1;
		if (closed == null) closed = db.close().ok;
	});
	// Either close refuses (the statement is in use) and every row is visited, or it is
	// documented to abort the iteration; it must never succeed and leave `iterate` reporting ok.
	assert closed != null;
	if (closed!) {
		assert !r.ok;
	} else {
		assert r.ok && visits == 3;
	}
}

test "prepare() with two statements is refused" {
	const db = memory();
	const two = db.prepare("SELECT 1; SELECT 2");
	assert !two.ok && two.error.code == ErrorCode.Misuse;
}

test "prepare() with two statements is refused after multi-byte text" {
	const db = memory();
	const sql = "SELECT '" + "é".repeat(20) + "'; SELECT 2";
	const two = db.prepare(sql);
	assert !two.ok, "the second statement was silently dropped";
}

test "run() does not silently drop a second statement after multi-byte text" {
	const db = memory();
	assert db.exec("CREATE TABLE t (s TEXT)").ok;
	const sql = "INSERT INTO t VALUES ('" + "🚀".repeat(10) + "'); DROP TABLE t";
	const r = db.run(sql);
	assert !r.ok, "run accepted two statements and ran only the first";
}

test "an empty or comment-only SQL is refused with Misuse" {
	const db = memory();
	const empty = db.prepare("");
	assert !empty.ok && empty.error.code == ErrorCode.Misuse;
	const comment = db.prepare("-- nothing here");
	assert !comment.ok && comment.error.code == ErrorCode.Misuse;
}

test "a syntax error carries the SQL and sqlite's message from every entry point" {
	const db = memory();
	const sql = "SELEKT 1 AS n";
	const p = db.prepare(sql);
	assert !p.ok && p.error.sql == sql && p.error.message.contains("syntax error");
	const q = db.all<Small>(sql);
	assert !q.ok && q.error.sql == sql && q.error.message.contains("syntax error");
	const e = db.exec(sql);
	assert !e.ok && e.error.sql == sql && e.error.message.contains("syntax error");
	assert e.error.toString().contains(sql);
}

struct HostOnly { host: string; }
struct HostBusy { host: string; busy: float64; }

test "named() with a missing field is refused naming the parameter" {
	const db = memory();
	const v: HostOnly = { host: "a" };
	const r = db.all<HostOnly>("SELECT :host AS host, :busy AS busy", named(v));
	assert !r.ok && r.error.code == ErrorCode.Range && r.error.message.contains(":busy");
}

test "named() with an extra field is refused naming the field" {
	const db = memory();
	const v: HostBusy = { host: "a", busy: 1.5 };
	const r = db.all<HostOnly>("SELECT :host AS host", named(v));
	assert !r.ok && r.error.code == ErrorCode.Range && r.error.message.contains("busy");
}

test "a ? or ?NNN parameter with named() is refused" {
	const db = memory();
	const v: HostOnly = { host: "a" };
	const bare = db.all<HostOnly>("SELECT ? AS host", named(v));
	assert !bare.ok && bare.error.code == ErrorCode.Range;
	const numbered = db.all<HostOnly>("SELECT ?1 AS host", named(v));
	assert !numbered.ok && numbered.error.code == ErrorCode.Range;
}

test "a named parameter used twice binds once from one field" {
	const db = memory();
	const v: HostOnly = { host: "a" };
	const r = db.get<HostOnly>("SELECT :host || :host AS host", named(v));
	assert r.ok && r.value != null && r.value!.host == "aa";
}

struct NoFields {}

test "named values are checked against the statement on every run, not only the first" {
	const db = memory();
	const sql = "SELECT :host AS host";
	const none: NoFields = {};
	const host: HostOnly = { host: "a" };
	const extra: HostBusy = { host: "b", busy: 1.5 };
	const empty = db.get<HostOnly>(sql, named(none));
	assert !empty.ok && empty.error.code == ErrorCode.Range;
	const first = db.get<HostOnly>(sql, named(host));
	assert first.ok && first.value != null && first.value!.host == "a";
	const more = db.get<HostOnly>(sql, named(extra));
	assert !more.ok && more.error.code == ErrorCode.Range && more.error.message.contains("busy");
	const fewer = db.get<HostOnly>(sql, named(none));
	assert !fewer.ok && fewer.error.code == ErrorCode.Range && fewer.error.message.contains(":host");
	const again = db.get<HostOnly>(sql, named(host));
	assert again.ok && again.value != null && again.value!.host == "a";
}

test "binding an index outside the statement is Range" {
	const db = memory();
	const p = db.prepare("SELECT ?");
	assert p.ok;
	const stmt = p.value;
	const zero = stmt.bind(0, Param.integer(1));
	assert !zero.ok && zero.error.code == ErrorCode.Range;
	const past = stmt.bind(2, Param.integer(1));
	assert !past.ok && past.error.code == ErrorCode.Range;
	stmt.finalize();
}

test "a finalized Statement refuses bind and step with Misuse; finalize twice is harmless" {
	const db = memory();
	const p = db.prepare("SELECT ?");
	assert p.ok;
	const stmt = p.value;
	stmt.finalize();
	stmt.finalize();
	const b = stmt.bind(1, Param.integer(1));
	assert !b.ok && b.error.code == ErrorCode.Misuse;
	const s = stmt.step();
	assert !s.ok && s.error.code == ErrorCode.Misuse;
	assert stmt.columnCount() == 0 && stmt.parameterCount() == 0;
	assert db.close().ok;
}

// Transactions

test "a body returning err rolls back its writes" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	const r = db.transaction((): Result<void, string> => {
		db.run("INSERT INTO t VALUES (1)");
		db.run("INSERT INTO t VALUES (2)");
		return Result.err("stop");
	}, message);
	assert !r.ok && r.error == "stop";
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
}

test "a throwing body rolls back and the next transaction commits" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	let caught = false;
	try {
		db.transaction((): Result<void, string> => {
			db.run("INSERT INTO t VALUES (1)");
			throw new Error("boom");
		}, message);
	} catch (e) {
		caught = true;
	}
	assert caught;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	const next = db.transaction((): Result<void, string> => {
		if (!db.run("INSERT INTO t VALUES (2)").ok) return Result.err("insert");
		return Result.ok(null);
	}, message);
	assert next.ok && count(db, "SELECT COUNT(*) AS n FROM t") == 1;
}

test "a throw two levels deep rolls back every level" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	let caught = false;
	try {
		db.transaction((): Result<void, string> => {
			db.run("INSERT INTO t VALUES (1)");
			return db.transaction((): Result<void, string> => {
				db.run("INSERT INTO t VALUES (2)");
				throw new Error("deep");
			}, message);
		}, message);
	} catch (e) {
		caught = true;
	}
	assert caught;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	assert db.transaction((): Result<void, string> => Result.ok(null), message).ok;
}

test "three levels with the middle failing keep only the outer work" {
	const db = memory();
	assert db.exec("CREATE TABLE t (n)").ok;
	const outer = db.transaction((): Result<void, string> => {
		if (!db.run("INSERT INTO t VALUES (1)").ok) return Result.err("outer");
		const middle = db.transaction((): Result<void, string> => {
			if (!db.run("INSERT INTO t VALUES (10)").ok) return Result.err("middle");
			const inner = db.transaction((): Result<void, string> => {
				if (!db.run("INSERT INTO t VALUES (100)").ok) return Result.err("inner");
				return Result.ok(null);
			}, message);
			if (!inner.ok) return inner;
			return Result.err("middle fails");
		}, message);
		if (middle.ok) return Result.err("middle should have failed");
		if (!db.run("INSERT INTO t VALUES (2)").ok) return Result.err("after middle");
		return Result.ok(null);
	}, message);
	assert outer.ok;
	assert count(db, "SELECT SUM(n) AS n FROM t") == 3;
}

test "a failed COMMIT rolls back and the next transaction works" {
	const db = memory();
	assert db.exec(
		"CREATE TABLE p (id INTEGER PRIMARY KEY); " +
			"CREATE TABLE c (pid INTEGER REFERENCES p (id) DEFERRABLE INITIALLY DEFERRED)",
	).ok;
	const failed = db.transaction((): Result<void, string> => {
		if (!db.run("INSERT INTO c VALUES (42)").ok) return Result.err("insert");
		return Result.ok(null);
	}, message);
	assert !failed.ok && failed.error.contains("FOREIGN KEY");
	assert count(db, "SELECT COUNT(*) AS n FROM c") == 0;
	const next = db.transaction((): Result<void, string> => {
		if (!db.run("INSERT INTO p VALUES (1)").ok) return Result.err("insert p");
		if (!db.run("INSERT INTO c VALUES (1)").ok) return Result.err("insert c");
		return Result.ok(null);
	}, message);
	assert next.ok, next.ok ? "" : next.error;
	assert count(db, "SELECT COUNT(*) AS n FROM c") == 1;
}

// A database whose native connection the test keeps, so it can lower sqlite's SQL length limit
// inside a transaction: a ROLLBACK not cached yet then fails to prepare with TooBig and the
// transaction stays open, the state a failed outermost rollback leaves.
function memoryKeeping(out pointer: Ptr<sqlite3>): Database {
	const rc = msqOpen(":memory:", OPEN_READWRITE_CREATE, out pointer);
	if (rc != 0) throw new Error(`sqlite3_open_v2 returned ${rc}`);
	return new Database(":memory:", new Connection(pointer), 64);
}

function stopped(): SqliteError {
	return { code: ErrorCode.Abort, extended: 4, message: "the body stops", sql: "" };
}

const BROKEN_BY_TOO_BIG = "a failed rollback left a transaction open " +
	"(string or blob too big); close the database";

function refusedAsBroken<T>(r: Result<T, SqliteError>): boolean {
	return !r.ok && r.error.code == ErrorCode.Misuse && r.error.message == BROKEN_BY_TOO_BIG;
}

// The first operation a broken database still accepts, or null when it refuses them all.
function acceptedWhileBroken(db: Database): string | null {
	if (!refusedAsBroken(db.run("INSERT INTO t VALUES (9)"))) return "run";
	if (!refusedAsBroken(db.run("INSERT INTO t VALUES (?)", [Param.integer(9)]))) return "run ?";
	if (!refusedAsBroken(db.get<Count>("SELECT COUNT(*) AS n FROM t"))) return "get";
	if (!refusedAsBroken(db.all<Count>("SELECT COUNT(*) AS n FROM t"))) return "all";
	if (!refusedAsBroken(db.allJson("SELECT 1"))) return "allJson";
	if (!refusedAsBroken(db.exec("ROLLBACK"))) return "exec";
	if (!refusedAsBroken(db.prepare("ROLLBACK"))) return "prepare";
	if (!refusedAsBroken(db.migrate(["CREATE TABLE a (x)"]))) return "migrate";
	const tx = db.transaction<void>((): Result<void, SqliteError> => Result.ok(null));
	if (!refusedAsBroken(tx)) return "transaction";
	return null;
}

test "a failed outermost rollback after a failed body breaks the database until close" {
	let pointer: Ptr<sqlite3>;
	const db = memoryKeeping(out pointer);
	assert db.exec("CREATE TABLE t (n)").ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	const r = db.transaction<void>((): Result<void, SqliteError> => {
		try db.run("INSERT INTO t VALUES (1)");
		sqliteLimit(pointer, SQLITE_LIMIT_SQL_LENGTH, 5);
		return Result.err(stopped());
	});
	assert !r.ok && r.error.code == ErrorCode.TooBig && r.error.sql == "ROLLBACK";
	const accepted = acceptedWhileBroken(db);
	assert accepted == null, `${accepted} ran on a broken database`;
	assert db.isOpen && db.close().ok && !db.isOpen;
}

test "a failed outermost rollback after a failed commit breaks the database until close" {
	let pointer: Ptr<sqlite3>;
	const db = memoryKeeping(out pointer);
	assert db.exec("CREATE TABLE t (n)").ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	const r = db.transaction<void>((): Result<void, SqliteError> => {
		try db.run("INSERT INTO t VALUES (1)");
		sqliteLimit(pointer, SQLITE_LIMIT_SQL_LENGTH, 5);
		return Result.ok(null);
	});
	assert !r.ok && r.error.code == ErrorCode.TooBig && r.error.sql == "ROLLBACK";
	const accepted = acceptedWhileBroken(db);
	assert accepted == null, `${accepted} ran on a broken database`;
	assert db.isOpen && db.close().ok && !db.isOpen;
}

test "a failed outermost rollback after a throwing body breaks the database until close" {
	let pointer: Ptr<sqlite3>;
	const db = memoryKeeping(out pointer);
	assert db.exec("CREATE TABLE t (n)").ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	let caught = false;
	try {
		db.transaction((): Result<void, string> => {
			db.run("INSERT INTO t VALUES (1)");
			sqliteLimit(pointer, SQLITE_LIMIT_SQL_LENGTH, 5);
			throw new Error("boom");
		}, message);
	} catch (e) {
		caught = true;
	}
	assert caught;
	const accepted = acceptedWhileBroken(db);
	assert accepted == null, `${accepted} ran on a broken database`;
	assert db.isOpen && db.close().ok && !db.isOpen;
}

test "a failed savepoint rollback leaves the database usable once the outer level rolls back" {
	let pointer: Ptr<sqlite3>;
	const db = memoryKeeping(out pointer);
	assert db.exec("CREATE TABLE t (n)").ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	let previous: int32 = 0;
	const outer = db.transaction<void>((): Result<void, SqliteError> => {
		try db.run("INSERT INTO t VALUES (1)");
		return db.transaction<void>((): Result<void, SqliteError> => {
			try db.run("INSERT INTO t VALUES (2)");
			previous = sqliteLimit(pointer, SQLITE_LIMIT_SQL_LENGTH, 10);
			return Result.err(stopped());
		});
	});
	assert !outer.ok && outer.error.code == ErrorCode.TooBig;
	assert outer.error.sql == "ROLLBACK TO msq_1";
	sqliteLimit(pointer, SQLITE_LIMIT_SQL_LENGTH, previous);
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 0;
	assert db.run("INSERT INTO t VALUES (3)").ok;
	assert count(db, "SELECT COUNT(*) AS n FROM t") == 1;
	assert db.close().ok;
}

// Statement cache

test "the same SQL run inside its own iterate visitor works and leaves one cached statement" {
	const db = memory();
	const sql = "SELECT value AS n FROM json_each(?)";
	let inner: int64 = 0;
	let nestedRows: int32 = 0;
	const r = db.iterate<Count>(sql, [Param.text("[1,2,3]")], (outer: Count): void => {
		const nested = db.iterate<Count>(sql, [Param.text("[5,6]")], (row: Count): void => {
			inner += row.n * outer.n;
		});
		if (nested.ok) nestedRows += nested.value;
	});
	assert r.ok && r.value == 3;
	assert nestedRows == 6 && inner == 66;
	assert db.openStatements() == 1;
	const again = db.all<Count>(sql, [Param.text("[7]")]);
	assert again.ok && again.value.length == 1 && again.value[0].n == 7;
}

test "a visitor that throws releases the cached statement for the next caller" {
	const db = memory();
	const sql = "SELECT value AS n FROM json_each('[1,2,3]')";
	let caught = false;
	try {
		db.iterate<Count>(sql, (row: Count): void => {
			throw new Error("visitor");
		});
	} catch (e) {
		caught = true;
	}
	assert caught;
	const r = db.all<Count>(sql);
	assert r.ok && r.value.length == 3;
	assert db.openStatements() == 1;
}

test "a decode failure does not leak into the next use of the cached statement" {
	const db = memory();
	const bad = db.all<Small>("SELECT ? AS n", [Param.integer(5000000000)]);
	assert !bad.ok && bad.error.code == ErrorCode.OutOfRange;
	const good = db.all<Small>("SELECT ? AS n", [Param.integer(5)]);
	assert good.ok && good.value[0].n == 5;
}

// Lifetime

function orphanStatement(): Statement {
	const db = memory();
	const setup = db.exec("CREATE TABLE t (n); INSERT INTO t VALUES (7), (8)");
	if (!setup.ok) throw new Error(setup.error.toString());
	const p = db.prepare("SELECT n FROM t ORDER BY n");
	if (!p.ok) throw new Error(p.error.toString());
	return p.value;
}

test "a Statement outliving its Database still steps and reads" {
	const stmt = orphanStatement();
	const first = stmt.step();
	assert first.ok && first.value;
	const n = stmt.integerAt(0);
	assert n.ok && n.value == 7;
	const second = stmt.step();
	assert second.ok && second.value;
	const done = stmt.step();
	assert done.ok && !done.value;
	stmt.finalize();
}

test "a Statement outliving its Database reports errors through the closing connection" {
	const stmt = orphanStatement();
	const r = stmt.bind(9, Param.integer(1));
	assert !r.ok && r.error.code == ErrorCode.Range && r.error.message != "";
}

test "a Statement outliving its Database is finalized by being dropped" {
	{
		const stmt = orphanStatement();
		assert stmt.step().ok;
	}
	const db = memory();
	assert db.close().ok;
}

test "a Database dropped without close() while its Statement is alive" {
	let stmt: Statement | null = null;
	{
		const db = memory();
		assert db.exec("CREATE TABLE t (n); INSERT INTO t VALUES (1)").ok;
		assert db.all<Count>("SELECT n FROM t").ok;
		const p = db.prepare("SELECT COUNT(*) FROM t");
		assert p.ok;
		stmt = p.value;
	}
	const s = stmt!;
	const stepped = s.step();
	assert stepped.ok && stepped.value;
	const n = s.integerAt(0);
	assert n.ok && n.value == 1;
	stmt = null;
}
