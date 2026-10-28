// Rows straight to JSON text for forwarding: an array of objects keyed by column name.
// INTEGER is exact decimal, REAL a JSON number (non-finite as null), TEXT a JSON string,
// BLOB a base64 string, NULL null.
import { ColumnKind, Statement } from "./statement";
import { SqliteError } from "./error";
import { encodeBase64 } from "std/crypto/encoding";

function cellJson(stmt: Statement, column: int32): Result<string, SqliteError> {
	return match (stmt.columnKind(column)) {
		ColumnKind.Null => Result.ok("null"),
		ColumnKind.Integer => Result.ok(String(try stmt.integerAt(column))),
		ColumnKind.Real => {
			const value = try stmt.realAt(column);
			Result.ok(Number.isFinite(value) ? String(value) : "null")
		},
		ColumnKind.Text => Result.ok(JSON.stringify(try stmt.textAt(column))),
		ColumnKind.Blob => Result.ok(`"${(try stmt.blobAt(column)).encodeBase64()}"`),
	};
}

// Steps `stmt` to the end, writing every row; the caller binds before and resets after.
// `out += try cellJson(...)` copies `out` per cell on C today, so this is quadratic in the rows
// until the compiler appends a `try` operand in place.
export function rowsJson(stmt: Statement): Result<string, SqliteError> {
	const count = stmt.columnCount();
	const keys: string[] = [];
	for (let c: int32 = 0; c < count; c++) {
		keys.push(`${c == 0 ? "" : ","}${JSON.stringify(stmt.columnName(c))}:`);
	}
	let out = "[";
	let rows: int32 = 0;
	while (try stmt.step()) {
		out += rows == 0 ? "{" : ",{";
		for (let c: int32 = 0; c < count; c++) {
			out += keys[c];
			out += try cellJson(stmt, c);
		}
		out += "}";
		rows += 1;
	}
	out += "]";
	return Result.ok(out);
}
