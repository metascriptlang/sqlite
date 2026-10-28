#include "sqlite.h"
#include "../../vendor/sqlite3/sqlite3.h"
#include <string.h>

int32_t msqOpen(const char *path, int32_t flags, sqlite3 **db) {
	*db = NULL;
	return sqlite3_open_v2(path, db, flags | SQLITE_OPEN_EXRESCODE, NULL);
}

int32_t msqClose(sqlite3 *db) { return sqlite3_close(db); }
void msqCloseLater(sqlite3 *db) { sqlite3_close_v2(db); }
int32_t msqBusyTimeout(sqlite3 *db, int32_t milliseconds) { return sqlite3_busy_timeout(db, milliseconds); }
const char *msqErrorMessage(sqlite3 *db) { return sqlite3_errmsg(db); }
const char *msqErrorString(int32_t code) { return sqlite3_errstr(code); }
int32_t msqExtendedCode(sqlite3 *db) { return sqlite3_extended_errcode(db); }
sqlite3 *msqStatementDatabase(sqlite3_stmt *stmt) { return sqlite3_db_handle(stmt); }
int32_t msqExec(sqlite3 *db, const char *sql) { return sqlite3_exec(db, sql, NULL, NULL, NULL); }

int32_t msqPrepare(sqlite3 *db, const char *sql, int32_t persistent, sqlite3_stmt **stmt, int32_t *tailBytes) {
	const char *tail = NULL;
	unsigned int flags = persistent ? SQLITE_PREPARE_PERSISTENT : 0;
	*stmt = NULL;
	int rc = sqlite3_prepare_v3(db, sql, -1, flags, stmt, &tail);
	*tailBytes = tail == NULL ? 0 : (int32_t)strlen(tail);
	return rc;
}

int32_t msqParameterCount(sqlite3_stmt *stmt) { return sqlite3_bind_parameter_count(stmt); }
const char *msqParameterName(sqlite3_stmt *stmt, int32_t index) { return sqlite3_bind_parameter_name(stmt, index); }
int32_t msqBindNull(sqlite3_stmt *stmt, int32_t index) { return sqlite3_bind_null(stmt, index); }
int32_t msqBindInt64(sqlite3_stmt *stmt, int32_t index, int64_t value) { return sqlite3_bind_int64(stmt, index, value); }
int32_t msqBindDouble(sqlite3_stmt *stmt, int32_t index, double value) { return sqlite3_bind_double(stmt, index, value); }

int32_t msqBindText(sqlite3_stmt *stmt, int32_t index, const uint8_t *data, int64_t length) {
	return sqlite3_bind_text64(stmt, index, length == 0 ? "" : (const char *)data, (sqlite3_uint64)length,
		SQLITE_TRANSIENT, SQLITE_UTF8);
}

int32_t msqBindBlob(sqlite3_stmt *stmt, int32_t index, const uint8_t *data, int64_t length) {
	if (length == 0) return sqlite3_bind_zeroblob(stmt, index, 0);
	return sqlite3_bind_blob64(stmt, index, data, (sqlite3_uint64)length, SQLITE_TRANSIENT);
}

int32_t msqStep(sqlite3_stmt *stmt) { return sqlite3_step(stmt); }
int32_t msqReprepareCount(sqlite3_stmt *stmt) { return sqlite3_stmt_status(stmt, SQLITE_STMTSTATUS_REPREPARE, 0); }
int32_t msqReset(sqlite3_stmt *stmt) { return sqlite3_reset(stmt); }
int32_t msqClearBindings(sqlite3_stmt *stmt) { return sqlite3_clear_bindings(stmt); }
int32_t msqFinalize(sqlite3_stmt *stmt) { return sqlite3_finalize(stmt); }
int32_t msqColumnCount(sqlite3_stmt *stmt) { return sqlite3_column_count(stmt); }
int32_t msqColumnType(sqlite3_stmt *stmt, int32_t column) { return sqlite3_column_type(stmt, column); }

const char *msqColumnName(sqlite3_stmt *stmt, int32_t column) {
	const char *name = sqlite3_column_name(stmt, column);
	return name == NULL ? "" : name;
}

int64_t msqColumnInt64(sqlite3_stmt *stmt, int32_t column) { return sqlite3_column_int64(stmt, column); }
double msqColumnDouble(sqlite3_stmt *stmt, int32_t column) { return sqlite3_column_double(stmt, column); }

const char *msqColumnText(sqlite3_stmt *stmt, int32_t column, int64_t *bytes) {
	const unsigned char *text = sqlite3_column_text(stmt, column);
	*bytes = sqlite3_column_bytes(stmt, column);
	return text == NULL ? "" : (const char *)text;
}

int64_t msqColumnBytes(sqlite3_stmt *stmt, int32_t column) { return sqlite3_column_bytes(stmt, column); }

void msqColumnBlobCopy(sqlite3_stmt *stmt, int32_t column, uint8_t *data, int64_t length) {
	const void *blob = sqlite3_column_blob(stmt, column);
	if (blob != NULL && length > 0) memcpy(data, blob, (size_t)length);
}

int64_t msqChanges(sqlite3 *db) { return sqlite3_changes64(db); }
int64_t msqLastInsertRowid(sqlite3 *db) { return sqlite3_last_insert_rowid(db); }
int32_t msqAutocommit(sqlite3 *db) { return sqlite3_get_autocommit(db); }

int32_t msqStatementCount(sqlite3 *db) {
	int32_t count = 0;
	for (sqlite3_stmt *stmt = sqlite3_next_stmt(db, NULL); stmt != NULL; stmt = sqlite3_next_stmt(db, stmt)) count++;
	return count;
}
const char *msqVersion(void) { return sqlite3_libversion(); }
