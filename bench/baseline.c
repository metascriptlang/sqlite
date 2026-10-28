// The work of bench/throughput.ms in plain C against the same amalgamation and flags; build:
// zig cc -O2 -w -DNDEBUG -ffp-contract=off -fno-strict-aliasing -fdata-sections -ffunction-sections
//   <the @compile flags of src/native.ms> bench/baseline.c vendor/sqlite3/sqlite3.c -o out/baseline
#include "../vendor/sqlite3/sqlite3.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { ROWS = 100000, LOOKUPS = 10000 };
static const char *WAL_PATH = "/tmp/msq-bench-c.db";

typedef struct {
	int64_t id;
	char *name;
	double score;
	int64_t n;
} Row;

typedef struct {
	char *data;
	size_t length, capacity;
} Buffer;

static double nowMs(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void report(const char *db, const char *label, double startMs, int ops, int64_t check) {
	double ns = (nowMs() - startMs) * 1e6 / ops;
	printf("%s %s %.0f %lld\n", db, label, ns, (long long)check);
}

static void must(int rc, sqlite3 *db, const char *what) {
	if (rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE) return;
	fprintf(stderr, "%s: %s\n", what, sqlite3_errmsg(db));
	exit(1);
}

static sqlite3_stmt *prepare(sqlite3 *db, const char *sql) {
	sqlite3_stmt *stmt = NULL;
	must(sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT, &stmt, NULL), db, sql);
	return stmt;
}

static const char *nameOf(int i) { return i % 2 == 0 ? "web-1" : "web-2"; }
static double scoreOf(int i) { return (i % 100) / 4.0; }

static void put(Buffer *b, const char *s, size_t n) {
	if (b->length + n > b->capacity) {
		while (b->length + n > b->capacity) b->capacity = b->capacity ? b->capacity * 2 : 4096;
		b->data = realloc(b->data, b->capacity);
	}
	memcpy(b->data + b->length, s, n);
	b->length += n;
}

static void putText(Buffer *b, const char *s) { put(b, s, strlen(s)); }

static void putJsonString(Buffer *b, const unsigned char *s, int n) {
	put(b, "\"", 1);
	for (int i = 0; i < n; i++) {
		unsigned char c = s[i];
		char escaped[8];
		if (c == '"' || c == '\\') {
			escaped[0] = '\\';
			escaped[1] = (char)c;
			put(b, escaped, 2);
		} else if (c < 0x20) {
			put(b, escaped, (size_t)snprintf(escaped, sizeof escaped, "\\u%04x", c));
		} else {
			put(b, (const char *)&c, 1);
		}
	}
	put(b, "\"", 1);
}

static char *copyText(sqlite3_stmt *stmt, int column) {
	const unsigned char *text = sqlite3_column_text(stmt, column);
	int n = sqlite3_column_bytes(stmt, column);
	char *copy = malloc((size_t)n + 1);
	memcpy(copy, text, (size_t)n);
	copy[n] = 0;
	return copy;
}

static void insertRows(sqlite3 *db, const char *label, const char *workload, const char *sql) {
	double start = nowMs();
	must(sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL), db, "begin");
	sqlite3_stmt *stmt = prepare(db, sql);
	for (int i = 0; i < ROWS; i++) {
		sqlite3_bind_text64(stmt, 1, nameOf(i), strlen(nameOf(i)), SQLITE_TRANSIENT, SQLITE_UTF8);
		sqlite3_bind_double(stmt, 2, scoreOf(i));
		sqlite3_bind_int64(stmt, 3, i);
		must(sqlite3_step(stmt), db, "insert");
		sqlite3_reset(stmt);
	}
	sqlite3_finalize(stmt);
	must(sqlite3_exec(db, "COMMIT", NULL, NULL, NULL), db, "commit");
	report(label, workload, start, ROWS, ROWS);
}

static void workloads(const char *label, sqlite3 *db) {
	must(sqlite3_exec(db,
		"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL, n INTEGER);"
		"CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT, score REAL, n INTEGER)",
		NULL, NULL, NULL), db, "schema");
	insertRows(db, label, "insert_positional", "INSERT INTO t (name, score, n) VALUES (?, ?, ?)");
	insertRows(db, label, "insert_named", "INSERT INTO u (name, score, n) VALUES (:name, :score, :n)");

	double start = nowMs();
	sqlite3_stmt *stmt = prepare(db, "SELECT id, name, score, n FROM t");
	size_t count = 0, capacity = 16;
	Row *rows = malloc(capacity * sizeof(Row));
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		if (count == capacity) rows = realloc(rows, (capacity *= 2) * sizeof(Row));
		rows[count++] = (Row){
			sqlite3_column_int64(stmt, 0), copyText(stmt, 1),
			sqlite3_column_double(stmt, 2), sqlite3_column_int64(stmt, 3),
		};
	}
	sqlite3_finalize(stmt);
	int64_t sum = 0;
	for (size_t i = 0; i < count; i++) {
		sum += rows[i].id + rows[i].n + (int64_t)strlen(rows[i].name) + (int64_t)(rows[i].score * 4);
	}
	report(label, "query_struct", start, (int)count, sum);
	for (size_t i = 0; i < count; i++) free(rows[i].name);
	free(rows);

	start = nowMs();
	stmt = prepare(db, "SELECT id, name, score, n FROM t");
	int columns = sqlite3_column_count(stmt);
	Buffer json = {0};
	putText(&json, "[");
	int rowCount = 0;
	char number[32];
	while (sqlite3_step(stmt) == SQLITE_ROW) {
		putText(&json, rowCount == 0 ? "{" : ",{");
		for (int c = 0; c < columns; c++) {
			if (c > 0) putText(&json, ",");
			const char *name = sqlite3_column_name(stmt, c);
			putJsonString(&json, (const unsigned char *)name, (int)strlen(name));
			putText(&json, ":");
			switch (sqlite3_column_type(stmt, c)) {
			case SQLITE_INTEGER:
				put(&json, number, (size_t)snprintf(number, sizeof number, "%lld",
					(long long)sqlite3_column_int64(stmt, c)));
				break;
			case SQLITE_FLOAT:
				put(&json, number, (size_t)snprintf(number, sizeof number, "%.17g",
					sqlite3_column_double(stmt, c)));
				break;
			case SQLITE_TEXT:
				putJsonString(&json, sqlite3_column_text(stmt, c), sqlite3_column_bytes(stmt, c));
				break;
			default:
				putText(&json, "null");
			}
		}
		putText(&json, "}");
		rowCount++;
	}
	putText(&json, "]");
	sqlite3_finalize(stmt);
	report(label, "query_json", start, ROWS, (int64_t)json.length);
	free(json.data);

	start = nowMs();
	stmt = prepare(db, "SELECT id, name, score, n FROM t WHERE id = ?");
	int64_t found = 0;
	for (int i = 0; i < LOOKUPS; i++) {
		sqlite3_bind_int64(stmt, 1, (int64_t)i * 7919 % ROWS + 1);
		if (sqlite3_step(stmt) == SQLITE_ROW) {
			Row row = {
				sqlite3_column_int64(stmt, 0), copyText(stmt, 1),
				sqlite3_column_double(stmt, 2), sqlite3_column_int64(stmt, 3),
			};
			found += row.n;
			free(row.name);
		}
		sqlite3_reset(stmt);
	}
	sqlite3_finalize(stmt);
	report(label, "query_one", start, LOOKUPS, found);
}

static sqlite3 *openDb(const char *path) {
	sqlite3 *db = NULL;
	int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX |
		SQLITE_OPEN_EXRESCODE;
	must(sqlite3_open_v2(path, &db, flags, NULL), db, path);
	sqlite3_busy_timeout(db, 5000);
	return db;
}

int main(void) {
	sqlite3 *db = openDb(":memory:");
	workloads("memory", db);
	sqlite3_close(db);
	char path[256];
	const char *suffixes[] = {"", "-wal", "-shm"};
	for (int i = 0; i < 3; i++) {
		snprintf(path, sizeof path, "%s%s", WAL_PATH, suffixes[i]);
		unlink(path);
	}
	db = openDb(WAL_PATH);
	must(sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL), db, "wal");
	workloads("wal", db);
	sqlite3_close(db);
	return 0;
}
