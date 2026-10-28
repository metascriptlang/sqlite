#pragma once
#include <stdint.h>

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;

int32_t msqOpen(const char *path, int32_t flags, sqlite3 **db);
int32_t msqClose(sqlite3 *db);
void msqCloseLater(sqlite3 *db);
int32_t msqBusyTimeout(sqlite3 *db, int32_t milliseconds);
const char *msqErrorMessage(sqlite3 *db);
const char *msqErrorString(int32_t code);
int32_t msqExtendedCode(sqlite3 *db);
sqlite3 *msqStatementDatabase(sqlite3_stmt *stmt);
int32_t msqExec(sqlite3 *db, const char *sql);
int32_t msqPrepare(sqlite3 *db, const char *sql, int32_t persistent, sqlite3_stmt **stmt, int32_t *tailBytes);
int32_t msqParameterCount(sqlite3_stmt *stmt);
const char *msqParameterName(sqlite3_stmt *stmt, int32_t index);
int32_t msqBindNull(sqlite3_stmt *stmt, int32_t index);
int32_t msqBindInt64(sqlite3_stmt *stmt, int32_t index, int64_t value);
int32_t msqBindDouble(sqlite3_stmt *stmt, int32_t index, double value);
int32_t msqBindText(sqlite3_stmt *stmt, int32_t index, const uint8_t *data, int64_t length);
int32_t msqBindBlob(sqlite3_stmt *stmt, int32_t index, const uint8_t *data, int64_t length);
int32_t msqStep(sqlite3_stmt *stmt);
int32_t msqReprepareCount(sqlite3_stmt *stmt);
int32_t msqReset(sqlite3_stmt *stmt);
int32_t msqClearBindings(sqlite3_stmt *stmt);
int32_t msqFinalize(sqlite3_stmt *stmt);
int32_t msqColumnCount(sqlite3_stmt *stmt);
int32_t msqColumnType(sqlite3_stmt *stmt, int32_t column);
const char *msqColumnName(sqlite3_stmt *stmt, int32_t column);
int64_t msqColumnInt64(sqlite3_stmt *stmt, int32_t column);
double msqColumnDouble(sqlite3_stmt *stmt, int32_t column);
const char *msqColumnText(sqlite3_stmt *stmt, int32_t column, int64_t *bytes);
int64_t msqColumnBytes(sqlite3_stmt *stmt, int32_t column);
void msqColumnBlobCopy(sqlite3_stmt *stmt, int32_t column, uint8_t *data, int64_t length);
int64_t msqChanges(sqlite3 *db);
int64_t msqLastInsertRowid(sqlite3 *db);
int32_t msqAutocommit(sqlite3 *db);
int32_t msqStatementCount(sqlite3 *db);
const char *msqVersion(void);
