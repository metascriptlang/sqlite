// The second OS process of test/contention.ms: takes the write lock on the database at argv's
// last argument, inserts one row, says "locked" on stdout and commits once stdin says "commit".
import { Database, SqliteError } from "../src/index";
import { readLine, writeStdout } from "std/io";
import { argv } from "std/process";

function holdWriteLock(path: string): Result<void, SqliteError> {
	const db = try Database.open(path);
	try db.exec("BEGIN IMMEDIATE; INSERT INTO t VALUES (1)");
	writeStdout("locked\n");
	const order = readLine().trim();
	if (order != "commit") throw new Error(`expected "commit" on stdin, got "${order}"`);
	try db.exec("COMMIT");
	return db.close();
}

when (!testBuild) {
	const held = holdWriteLock(argv[argv.length - 1]);
	if (!held.ok) throw new Error(held.error.toString());
}
