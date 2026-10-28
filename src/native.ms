// The owners of the two native SQLite resources and the error read from a connection.
// Each owner is a leaf holding only its pointer, so its destroy hook releases exactly that.
import {
	sqlite3, sqlite3_stmt, msqCloseLater, msqErrorMessage, msqErrorString, msqExtendedCode,
	msqFinalize, msqStatementDatabase,
} from "./native/sqlite.h";
import { ErrorCode, SqliteError, errorCodeOf } from "./error";

export const SQLITE_OK: int32 = 0;
const SQLITE_MISUSE: int32 = 21;

// The vendored amalgamation (vendor/sqlite3/VERSION), built with the options sqlite.org
// recommends for an embedding application, plus FTS5; JSON functions are built in. Foreign keys
// are enforced unless a connection turns them off, and a misused handle is an error, not a crash.
// The flags stay one string literal: the compiler ignores a flags argument built by
// concatenation.
@compile(
	"../vendor/sqlite3/sqlite3.c",
	"-DSQLITE_DQS=0 -DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_DEFAULT_FOREIGN_KEYS=1 -DSQLITE_ENABLE_API_ARMOR -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_USE_ALLOCA -DSQLITE_ENABLE_FTS5",
);
when (linux) {
	@passL("-lm");
}

when (js) {
	import { nativeOnly } from "./target";
	nativeOnly("sqlite");
}

export class Connection {
	pointer: Ptr<sqlite3> | null;
	constructor(pointer: Ptr<sqlite3>) { this.pointer = pointer; }
}

// A connection dropped without close() closes once its last statement is finalized.
function onDestroy(this connection: Connection): void {
	const pointer = connection.pointer;
	if (pointer != null) msqCloseLater(pointer);
	connection.pointer = null;
}

export class StatementHandle {
	pointer: Ptr<sqlite3_stmt> | null;
	constructor(pointer: Ptr<sqlite3_stmt>) { this.pointer = pointer; }
}

function onDestroy(this handle: StatementHandle): void {
	const pointer = handle.pointer;
	if (pointer != null) msqFinalize(pointer);
	handle.pointer = null;
}

// The connection's current error for a call that returned `resultCode`.
export function failure(this connection: Connection, resultCode: int32, sql: string): SqliteError {
	const pointer = connection.pointer;
	if (pointer == null) return misuse("the database is closed", sql);
	return connectionFailure(pointer, resultCode, sql);
}

// The error of the connection `stmt` was prepared on; sqlite keeps that connection open until
// the statement is finalized, so a statement needs no reference to its Database.
export function statementFailure(
	stmt: Ptr<sqlite3_stmt>,
	resultCode: int32,
	sql: string,
): SqliteError {
	return connectionFailure(msqStatementDatabase(stmt), resultCode, sql);
}

function connectionFailure(pointer: Ptr<sqlite3>, resultCode: int32, sql: string): SqliteError {
	return {
		code: errorCodeOf(resultCode),
		extended: msqExtendedCode(pointer),
		message: msqErrorMessage(pointer) as string,
		sql: sql,
	};
}

// An error sqlite reported only as a result code, with no connection to ask.
export function codeFailure(resultCode: int32, sql: string): SqliteError {
	return {
		code: errorCodeOf(resultCode),
		extended: resultCode,
		message: msqErrorString(resultCode) as string,
		sql: sql,
	};
}

export function misuse(message: string, sql: string): SqliteError {
	return { code: ErrorCode.Misuse, extended: SQLITE_MISUSE, message: message, sql: sql };
}
