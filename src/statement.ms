// A prepared statement: bind, step, read columns, reset. It owns its native statement through
// a leaf handle, so dropping it finalizes once; finalize() does it now.
import {
	sqlite3_stmt, msqBindDouble, msqBindInt64, msqBindNull, msqClearBindings, msqColumnBytes,
	msqColumnCount, msqColumnDouble, msqColumnInt64, msqColumnName, msqColumnText, msqColumnType,
	msqFinalize, msqParameterCount, msqParameterName, msqReset, msqStep,
} from "./native/sqlite.h";
import { SQLITE_OK, StatementHandle, misuse, statementFailure } from "./native";
import { ErrorCode, SqliteError } from "./error";
import { Named, Param, ParamKind } from "./param";

extern function msqBindText(
	stmt: Ptr<sqlite3_stmt>,
	index: int32,
	bytes: Readonly<Span<uint8>>,
): int32;
extern function msqBindBlob(
	stmt: Ptr<sqlite3_stmt>,
	index: int32,
	bytes: Readonly<Span<uint8>>,
): int32;
extern function msqColumnBlobCopy(stmt: Ptr<sqlite3_stmt>, column: int32, into: Span<uint8>): void;

const SQLITE_ROW: int32 = 100;
const SQLITE_DONE: int32 = 101;
const SQLITE_RANGE: int32 = 25;
const MAX_EXACT_INTEGER: int64 = 9007199254740992;

export enum ColumnKind {
	Integer,
	Real,
	Text,
	Blob,
	Null,
}

function columnKindOf(code: int32): ColumnKind {
	return match (code) {
		1 => ColumnKind.Integer,
		2 => ColumnKind.Real,
		3 => ColumnKind.Text,
		4 => ColumnKind.Blob,
		_ => ColumnKind.Null,
	};
}

function kindName(kind: ColumnKind): string {
	return match (kind) {
		ColumnKind.Integer => "INTEGER",
		ColumnKind.Real => "REAL",
		ColumnKind.Text => "TEXT",
		ColumnKind.Blob => "BLOB",
		ColumnKind.Null => "NULL",
	};
}

export class Statement {
	readonly sql: string;
	private handle: StatementHandle;
	// The first failed field read of the row being decoded.
	decodeFailure: SqliteError | null = null;

	constructor(sql: string, handle: StatementHandle) {
		this.sql = sql;
		this.handle = handle;
	}

	private live(): Result<Ptr<sqlite3_stmt>, SqliteError> {
		const pointer = this.handle.pointer;
		if (pointer == null) return Result.err(misuse("the statement is finalized", this.sql));
		return Result.ok(pointer);
	}

	private checked(pointer: Ptr<sqlite3_stmt>, resultCode: int32): Result<void, SqliteError> {
		if (resultCode == SQLITE_OK) return Result.ok(null);
		return Result.err(statementFailure(pointer, resultCode, this.sql));
	}

	get isFinalized(): boolean {
		return this.handle.pointer == null;
	}

	// Finalizes now; later calls on this statement fail with Misuse.
	finalize(): void {
		const handle = this.handle;
		const pointer = handle.pointer;
		if (pointer == null) return;
		handle.pointer = null;
		msqFinalize(pointer);
	}

	parameterCount(): int32 {
		const pointer = this.handle.pointer;
		return pointer == null ? 0 : msqParameterCount(pointer);
	}

	// Binds `value` to the 1-based parameter `index` with its exact storage class.
	bind(index: int32, value: Readonly<Param>): Result<void, SqliteError> {
		const pointer = try this.live();
		const rc = match (value.kind) {
			ParamKind.Null => msqBindNull(pointer, index),
			ParamKind.Integer => msqBindInt64(pointer, index, value.integer),
			ParamKind.Real => {
				if (Number.isNaN(value.real)) {
					const nan = `parameter ${index} is NaN, which SQLite would store as NULL`;
					return Result.err(this.rangeError(nan));
				}
				msqBindDouble(pointer, index, value.real)
			},
			ParamKind.Text => msqBindText(pointer, index, value.text.asBytes()),
			ParamKind.Blob => msqBindBlob(pointer, index, value.blob),
		};
		return this.checked(pointer, rc);
	}

	// Binds every parameter in order; the count must match the statement's parameters.
	bindAll(params: Readonly<Span<Param>>): Result<void, SqliteError> {
		const expected = this.parameterCount();
		if (params.length != expected) {
			return Result.err({
				code: ErrorCode.Range,
				extended: SQLITE_RANGE,
				message: `the statement takes ${expected} parameters, ${params.length} were given`,
				sql: this.sql,
			});
		}
		for (let i: int32 = 0; i < params.length; i++) try this.bind(i + 1, params[i]);
		return Result.ok(null);
	}

	// Binds each `:name`, `@name` or `$name` parameter from the value of the same name; every
	// parameter needs a value and every value a parameter.
	bindAll(values: Readonly<Named>): Result<void, SqliteError> {
		const names = values.names;
		const count = this.parameterCount();
		const used: boolean[] = names.map((name: string): boolean => false);
		for (let index: int32 = 1; index <= count; index++) {
			const marker = this.parameterName(index);
			if (marker == "" || marker.startsWith("?")) {
				const positional = `parameter ${index} is positional; ` +
					"named values bind only :name, @name or $name";
				return Result.err(this.rangeError(positional));
			}
			const at = names.indexOf(marker.slice(1, marker.length)) as int32;
			if (at < 0) return Result.err(this.rangeError(`no value for parameter ${marker}`));
			used[at] = true;
			try this.bind(index, values.params[at]);
		}
		for (let i: int32 = 0; i < names.length; i++) {
			if (!used[i]) {
				const unused = `the statement has no parameter for "${names[i]}"`;
				return Result.err(this.rangeError(unused));
			}
		}
		return Result.ok(null);
	}

	private parameterName(index: int32): string {
		const pointer = this.handle.pointer;
		if (pointer == null) return "";
		const name = msqParameterName(pointer, index);
		return name == null ? "" : name as string;
	}

	private rangeError(message: string): SqliteError {
		return { code: ErrorCode.Range, extended: SQLITE_RANGE, message: message, sql: this.sql };
	}

	// True when a row is ready to read, false when the statement has finished.
	step(): Result<boolean, SqliteError> {
		const pointer = try this.live();
		const rc = msqStep(pointer);
		if (rc == SQLITE_ROW) return Result.ok(true);
		if (rc == SQLITE_DONE) return Result.ok(false);
		return Result.err(statementFailure(pointer, rc, this.sql));
	}

	// Rewinds to run again; bindings stay until clearBindings().
	reset(): void {
		const pointer = this.handle.pointer;
		if (pointer != null) msqReset(pointer);
	}

	clearBindings(): void {
		const pointer = this.handle.pointer;
		if (pointer != null) msqClearBindings(pointer);
	}

	columnCount(): int32 {
		const pointer = this.handle.pointer;
		return pointer == null ? 0 : msqColumnCount(pointer);
	}

	columnName(column: int32): string {
		const pointer = this.handle.pointer;
		return pointer == null ? "" : msqColumnName(pointer, column) as string;
	}

	// The storage class of `column` in the current row.
	columnKind(column: int32): ColumnKind {
		const pointer = this.handle.pointer;
		return pointer == null ? ColumnKind.Null : columnKindOf(msqColumnType(pointer, column));
	}

	private wrongKind(column: int32, field: string, wanted: string): SqliteError {
		const kind = kindName(this.columnKind(column));
		return {
			code: ErrorCode.WrongKind,
			extended: 0,
			message: `column "${this.columnName(column)}" holds ${kind}, ${field} wants ${wanted}`,
			sql: this.sql,
		};
	}

	private outOfRange(column: int32, field: string, shown: string, range: string): SqliteError {
		return {
			code: ErrorCode.OutOfRange,
			extended: 0,
			message: `column "${this.columnName(column)}" holds ${shown}, ` +
				`outside ${field} (${range})`,
			sql: this.sql,
		};
	}

	// The INTEGER in `column`; any other storage class is WrongKind.
	integerAt(column: int32): Result<int64, SqliteError> {
		return this.integerOf(column, "an integer read");
	}

	private integerOf(column: int32, field: string): Result<int64, SqliteError> {
		const pointer = try this.live();
		if (this.columnKind(column) != ColumnKind.Integer) {
			return Result.err(this.wrongKind(column, field, "INTEGER"));
		}
		return Result.ok(msqColumnInt64(pointer, column));
	}

	// The REAL in `column`, or an INTEGER float64 holds exactly.
	realAt(column: int32): Result<float64, SqliteError> {
		return this.realOf(column, "a real read");
	}

	private realOf(column: int32, field: string): Result<float64, SqliteError> {
		const pointer = try this.live();
		const kind = this.columnKind(column);
		if (kind == ColumnKind.Real) return Result.ok(msqColumnDouble(pointer, column));
		if (kind != ColumnKind.Integer) return Result.err(this.wrongKind(column, field, "REAL"));
		const n = msqColumnInt64(pointer, column);
		if (n > MAX_EXACT_INTEGER || n < -MAX_EXACT_INTEGER) {
			const range = "an integer float64 holds exactly";
			return Result.err(this.outOfRange(column, field, String(n), range));
		}
		return Result.ok(n as float64);
	}

	// The TEXT in `column`.
	textAt(column: int32): Result<string, SqliteError> {
		return this.textOf(column, "a text read");
	}

	private textOf(column: int32, field: string): Result<string, SqliteError> {
		const pointer = try this.live();
		if (this.columnKind(column) != ColumnKind.Text) {
			return Result.err(this.wrongKind(column, field, "TEXT"));
		}
		let bytes: int64 = 0;
		const text = msqColumnText(pointer, column, bytes) as string;
		if (text.byteLength() as int64 != bytes) {
			return Result.err(this.outOfRange(column, field, "a NUL byte", "text without NUL"));
		}
		return Result.ok(text);
	}

	// A copy of the BLOB in `column`.
	blobAt(column: int32): Result<uint8[], SqliteError> {
		return this.blobOf(column, "a blob read");
	}

	private blobOf(column: int32, field: string): Result<uint8[], SqliteError> {
		const pointer = try this.live();
		if (this.columnKind(column) != ColumnKind.Blob) {
			return Result.err(this.wrongKind(column, field, "BLOB"));
		}
		const length = msqColumnBytes(pointer, column) as int32;
		const bytes = new Array<uint8>(length);
		msqColumnBlobCopy(pointer, column, bytes);
		return Result.ok(bytes);
	}

	isNull(column: int32): boolean {
		return this.columnKind(column) == ColumnKind.Null;
	}

	// Column index of each field name, or MissingColumn naming the field and the columns.
	columnIndexes(fields: Readonly<Span<string>>): Result<int32[], SqliteError> {
		const count = this.columnCount();
		const names: string[] = [];
		for (let c: int32 = 0; c < count; c++) names.push(this.columnName(c));
		const indexes: int32[] = [];
		for (const field of fields) {
			const at = names.indexOf(field) as int32;
			if (at < 0) {
				return Result.err({
					code: ErrorCode.MissingColumn,
					extended: 0,
					message: `no column "${field}" for field ${field}; the statement returns ` +
						(count == 0 ? "no columns" : names.join(", ")),
					sql: this.sql,
				});
			}
			indexes.push(at);
		}
		return Result.ok(indexes);
	}

	private record(error: SqliteError): void {
		if (this.decodeFailure == null) this.decodeFailure = error;
	}

	// Decode reads used by rowDecode: each records its failure and returns a placeholder the
	// caller discards with the row.
	fieldInt64(column: int32, field: string): int64 {
		const r = this.integerOf(column, field);
		if (r.ok) return r.value;
		this.record(r.error);
		return 0;
	}

	fieldInteger(column: int32, field: string, min: int64, max: int64): int64 {
		const r = this.integerOf(column, field);
		if (!r.ok) {
			this.record(r.error);
			return 0;
		}
		if (r.value < min || r.value > max) {
			this.record(this.outOfRange(column, field, String(r.value), `${min}..${max}`));
			return 0;
		}
		return r.value;
	}

	fieldReal(column: int32, field: string): float64 {
		const r = this.realOf(column, field);
		if (r.ok) return r.value;
		this.record(r.error);
		return 0;
	}

	fieldBoolean(column: int32, field: string): boolean {
		const n = this.fieldInteger(column, field, 0, 1);
		return n == 1;
	}

	fieldText(column: int32, field: string): string {
		const r = this.textOf(column, field);
		if (r.ok) return r.value;
		this.record(r.error);
		return "";
	}

	fieldBlob(column: int32, field: string): uint8[] {
		const r = this.blobOf(column, field);
		if (r.ok) return r.value;
		this.record(r.error);
		return [];
	}
}
