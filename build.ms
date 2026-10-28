import { BuildConfig } from "std/build";

const config: BuildConfig = {
	entry: "./src/index.ms",
	fmt: {
		useTabs: true,
	},
	package: {
		name: "@metascript/sqlite",
		version: "0.1.0",
		description: "SQLite driver for MetaScript: vendored amalgamation, typed rows, transactions",
		license: "MIT",
		files: ["src/**/*.ms", "src/native/*.c", "src/native/*.h", "vendor/sqlite3/*"],
	},
};

export default config;
