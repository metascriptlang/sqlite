# sqlite

SQLite for [MetaScript](https://github.com/metascriptlang): rows decode straight into your
structs, every failure is a `Result`, and the database engine ships inside the package.

```ts
import { Database, Param, SqliteError, named } from "sqlite/src/index";

struct Host {
	name: string;
	cores: int32;
	busy: float64;
}

function inventory(): Result<void, SqliteError> {
	const db = try Database.open("fleet.db");
	try db.exec("CREATE TABLE IF NOT EXISTS hosts (name TEXT PRIMARY KEY, cores INTEGER, busy REAL)");

	const web: Host = { name: "web-1", cores: 8, busy: 0.25 };
	try db.run("INSERT INTO hosts VALUES (:name, :cores, :busy)", named(web));

	const idle = try db.all<Host>("SELECT * FROM hosts WHERE busy < ?", [Param.real(0.5)]);
	const big = try db.get<Host>("SELECT * FROM hosts WHERE cores >= ?", [Param.integer(4)]);
	if (big != null) console.log(`${idle.length} idle, ${big.name} has the cores`);
	return Result.ok(null);
}
```

`all<Host>` is checked when it compiles: the decoder for `Host` is generated from the
struct's field types, and a struct field the result set does not have fails the query with
`MissingColumn` instead of becoming a default.

Native targets only; the JS backend has no SQLite.

## Install

Add the package to your project's `build.ms`:

```ts
deps: { "sqlite": "file:../sqlite" },
```

and import from `"sqlite/src/index"`. There is nothing else to install: SQLite 3.54.1 is
vendored as the amalgamation (`vendor/sqlite3`, checksum in `VERSION`) and compiled with your
program.

## What you get

**Rows as structs.** Each field reads the column of its name. The value is checked, never
coerced:

| Field type | Accepts | Refused with |
|---|---|---|
| `int8` … `int64`, `uint8` … `uint32` | INTEGER within the field's range | `OutOfRange`, `WrongKind` |
| `float64` | REAL, or an INTEGER that converts exactly | `WrongKind` |
| `boolean` | INTEGER 0 or 1 | `OutOfRange` |
| `string` | TEXT without NUL bytes | `WrongKind` |
| `uint8[]` | BLOB | `WrongKind` |
| `T \| null` | NULL, or whatever `T` accepts | |

A NULL in a field that is not `T | null` is refused rather than turned into `0` or `""`.
`uint64` is refused at compile time because SQLite integers are signed 64-bit.

**Parameters, by position or by name.** Positional values carry their storage class:
`Param.integer(42)`, `Param.real(0.5)`, `Param.text("x")`, `Param.blob(bytes)`, `Param.null()`,
and `Param.maybe<int64>(value, (n: int64): Param => Param.integer(n))` for a value that may be
null. `named(value)` binds a struct's fields to `:name`, `@name` or `$name` parameters. A
parameter with no field, or a field with no parameter, is an error, so a typo in either place
cannot pass silently. A statement without parameters takes none (`db.run("DELETE FROM hosts")`),
and one that has parameters is refused when they are not given. `NaN` is refused because SQLite
would store it as NULL.

**Transactions that nest.** `transaction` runs `BEGIN IMMEDIATE` at the outermost level and a
`SAVEPOINT` inside another one. A body that returns an error or throws rolls back to where it
began:

```ts
const reset = db.transaction<int64>((): Result<int64, SqliteError> => {
	const updated = try db.run("UPDATE hosts SET busy = 0 WHERE busy > ?", [Param.real(0.9)]);
	return Result.ok(updated.changes);
});
```

A body with its own error type passes a second argument that turns a failure to begin, commit
or roll back into that type: `db.transaction<int64, string>(body, (error) => error.toString())`.

If the outermost rollback itself fails and leaves the transaction open, the database refuses every
later call with `Misuse` ("a failed rollback left a transaction open (…); close the database"),
because the next statement would otherwise run inside the transaction that was meant to be gone.
`close()` still closes it, and closing rolls the open transaction back. A failed rollback of a
nested transaction does not break the database, because the outer level still rolls back.

**Migrations.** `migrate(steps)` brings the schema to version `steps.length` using
`PRAGMA user_version`. Each step and its version bump commit together, so a failed step leaves
the database at the last good version. A database newer than the program is refused, and so
is a negative version.

```ts
try db.migrate([
	"CREATE TABLE hosts (name TEXT PRIMARY KEY, cores INTEGER)",
	"ALTER TABLE hosts ADD COLUMN busy REAL",
]);
```

**Rows as JSON.** `allJson` returns the rows as a JSON array, for an endpoint that forwards
them unchanged. INTEGER becomes a number, BLOB a base64 string.

**A statement cache.** Every query method reuses a prepared statement per SQL text (64 by
default, least recently used evicted). `prepare` gives you a statement of your own when you
need one.

## Safe defaults

`Database.open` with `DEFAULT_OPEN_OPTIONS` gives you:

- **Foreign keys enforced.** SQLite leaves them off unless asked; this build turns them on.
- **A 5 s busy timeout.** A second writer waits for the lock instead of failing at once.
- **One statement per `run`.** `"SELECT 1; DROP TABLE t"` is refused, not half-run. `exec`
  runs several statements and takes no parameters.
- **Double-quoted strings refused.** `"name"` is an identifier, never a string literal.
- **No loadable extensions, no shared cache, no deprecated APIs.** The engine is built with
  the flags sqlite.org recommends for embedding (`src/native.ms`), plus FTS5. `PRAGMA
  compile_options` lists them.
- **API armor.** A misused handle returns `Misuse` instead of crashing the process.

Resources are owned: a `Database` or `Statement` that goes out of scope finalizes and closes
itself, in either order. `close()` returns `Busy` while you still hold a statement, and the
database stays usable.

## Threads and actors

A connection opened with `Threading.SingleOwner` (the default) is used by one owner at a time,
and the compiler refuses to share it between threads. To share a database across tasks, give it
to an actor and send it your application's messages:

```ts
actor Samples {
	private db: Database | null = null;

	constructor(path: string) {
		const opened = Database.open(path);
		if (opened.ok) this.db = opened.value;
	}

	record(sample: Sample): void {                        // a SEND: fire and forget
		const db = this.db;
		if (db != null) db.run("INSERT INTO samples VALUES (:host, :busy)", named(sample));
	}

	busiest(): Result<Sample | null, SqliteError> {       // a CALL: await the reply
		const db = this.db;
		if (db == null) return Result.ok(null);
		return db.get<Sample>("SELECT host, busy FROM samples ORDER BY busy DESC LIMIT 1");
	}
}
```

Keep each transaction inside one message, so another caller's message cannot land in the middle
of it. `test/actorOwner.ms` is a complete example that also keeps its errors.

An actor that owns the writer can also group commits: many small `record` SENDs share one
`COMMIT` (see `bench/actors.ms`).

## Performance

Measured on an Apple M-series Mac (14 cores) that was also running other work, so read the
ratios, not the absolute times. `--release` build, in-memory database, medians of 5 runs
interleaved with the C program. The C column does the same work directly against the same
amalgamation with the same flags (`bench/baseline.c`).

| Workload | MetaScript | C | Ratio |
|---|---|---|---|
| INSERT, positional parameters, one transaction | 243 ns | 174 ns | 1.4× |
| INSERT, `named(...)` | 295 ns | 178 ns | 1.7× |
| `all<T>`, per row | 149 ns | 70 ns | 2.1× |
| `get<T>` by primary key | 551 ns | 379 ns | 1.5× |
| `allJson`, per row | 507 µs | 305 ns | see below |

Group commit through an actor, WAL file, 20 000 rows (`bench/actors.ms`, measured in an earlier
session): 16.2 µs per row with
a commit per row, 1.7 µs per row with one writer actor committing every 256 rows (9.5×).

Known gaps, each traced to its cause:

- `allJson` is quadratic in the result size because of a compiler issue: appending the result
  of a `try` expression to a string copies the whole string. Writing the cell into a local first
  measures 642 ns per row (1.4× C). The fix belongs in the compiler, so the library waits for it.
- Decoding a TEXT column copies the string once more than it needs to, because of a compiler
  issue: returning a field of a local `Result` copies it instead of moving it. Without that copy
  `all<T>` runs 114 instead of 132 ns per row in the same session (16% fewer instructions). The
  fix belongs in the compiler.
- Reader actors do not yet read in parallel: actors created on the main thread currently share
  one scheduler, so eight reader actors read no faster than one. The runtime fix is designed;
  `spawn` already scales across cores.

Run the benchmarks with `msc run --release bench/throughput.ms` and
`msc run --release bench/actors.ms`.

## Errors

Every operation returns `Result<T, SqliteError>`. A `SqliteError` carries the primary code as an
`ErrorCode` case (`Busy`, `Constraint`, `Misuse`, …), SQLite's extended code, SQLite's message
and the SQL that failed. Decoding adds three codes of its own: `MissingColumn`, `WrongKind` and
`OutOfRange`.

```ts
const inserted = db.run(
	"INSERT INTO hosts VALUES (?, ?, ?)",
	[Param.text("web-1"), Param.integer(8), Param.real(0)],
);
if (!inserted.ok && inserted.error.code == ErrorCode.Constraint) {
	console.log(`already there: ${inserted.error.message}`);
}
```

## Limits

- Native only.
- No backup, interrupt, user-defined functions, update hooks, or `serialize` yet. They will
  arrive when an application needs them.
- A struct field must have the column's name; alias the column (`SELECT count(*) AS n`) when it
  does not.
- Named values go through `named(...)` instead of a plain object. A plain object waits on a
  compiler fix for an empty array literal passed to a generic parameter.
- `Param.maybe(value, Param.integer)` does not compile yet: a static extension passed as a
  function value is a compiler bug. Pass an arrow, as above.

## Development

```bash
msc test src/database.ms                                  # the library's own tests
msc test test/edges.ms                                    # boundary values and misuse
msc test test/contention.ms                               # two connections, two processes
msc test test/actorOwner.ms                               # a database inside an actor
msc test src/database.ms --sanitize=address --cc=clang    # the same under AddressSanitizer
```

`test/contention.ms` starts a second process through `msc run`, so `msc` must be on `PATH`.
Run each test file under `--sanitize=address --cc=clang` too; `test/contention.ms` also runs
under `--sanitize=thread --cc=clang`.

## License

MIT, see [LICENSE](LICENSE). The vendored SQLite amalgamation is in the public domain.
