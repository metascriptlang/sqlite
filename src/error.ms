// A failed SQLite call: the primary result code as a case, the extended code, sqlite's own
// message and the statement that failed.

export enum ErrorCode {
	Generic,
	Internal,
	Permission,
	Abort,
	Busy,
	Locked,
	NoMemory,
	ReadOnly,
	Interrupt,
	IO,
	Corrupt,
	NotFound,
	Full,
	CantOpen,
	Protocol,
	Schema,
	TooBig,
	Constraint,
	Mismatch,
	Misuse,
	NoLargeFile,
	Authorization,
	Range,
	NotADatabase,
	MissingColumn,
	WrongKind,
	OutOfRange,
}

export struct SqliteError {
	code: ErrorCode;
	extended: int32;
	message: string;
	sql: string;
}

// The case of a sqlite primary result code; `extended` keeps the full code.
export function errorCodeOf(resultCode: int32): ErrorCode {
	return match (resultCode & 255) {
		2 => ErrorCode.Internal,
		3 => ErrorCode.Permission,
		4 => ErrorCode.Abort,
		5 => ErrorCode.Busy,
		6 => ErrorCode.Locked,
		7 => ErrorCode.NoMemory,
		8 => ErrorCode.ReadOnly,
		9 => ErrorCode.Interrupt,
		10 => ErrorCode.IO,
		11 => ErrorCode.Corrupt,
		12 => ErrorCode.NotFound,
		13 => ErrorCode.Full,
		14 => ErrorCode.CantOpen,
		15 => ErrorCode.Protocol,
		17 => ErrorCode.Schema,
		18 => ErrorCode.TooBig,
		19 => ErrorCode.Constraint,
		20 => ErrorCode.Mismatch,
		21 => ErrorCode.Misuse,
		22 => ErrorCode.NoLargeFile,
		23 => ErrorCode.Authorization,
		25 => ErrorCode.Range,
		26 => ErrorCode.NotADatabase,
		_ => ErrorCode.Generic,
	};
}

export function toString(this error: SqliteError): string {
	const where = error.sql == "" ? "" : ` in: ${error.sql}`;
	return `${error.message} (${error.code.toString()})${where}`;
}

test "result codes map to their case, extended codes by their primary byte" {
	assert errorCodeOf(5) == ErrorCode.Busy;
	assert errorCodeOf(2067) == ErrorCode.Constraint;
	assert errorCodeOf(266) == ErrorCode.IO;
	assert errorCodeOf(1) == ErrorCode.Generic;
	assert errorCodeOf(21) == ErrorCode.Misuse;
}

test "an error reads as message, case and statement" {
	const e: SqliteError = {
		code: ErrorCode.Busy, extended: 5, message: "database is locked", sql: "BEGIN",
	};
	assert e.toString() == "database is locked (Busy) in: BEGIN";
}
