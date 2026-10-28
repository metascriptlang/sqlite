// A value bound to a statement parameter, carrying its exact SQLite storage class.
import { namedValues } from "./decode";

export enum ParamKind {
	Null,
	Integer,
	Real,
	Text,
	Blob,
}

export struct Param = match (kind: ParamKind) {
	ParamKind.Null => {},
	ParamKind.Integer => { integer: int64 },
	ParamKind.Real => { real: float64 },
	ParamKind.Text => { text: string },
	ParamKind.Blob => { blob: uint8[] },
};

export function integer(this typeof Param, value: int64): Param {
	return { kind: ParamKind.Integer, integer: value };
}

export function real(this typeof Param, value: float64): Param {
	return { kind: ParamKind.Real, real: value };
}

export function text(this typeof Param, value: string): Param {
	return { kind: ParamKind.Text, text: value };
}

export function blob(this typeof Param, value: uint8[]): Param {
	return { kind: ParamKind.Blob, blob: value };
}

export function null(this typeof Param): Param {
	return { kind: ParamKind.Null };
}

// `null` binds SQL NULL; any other value binds as `make` builds it.
export function maybe<T>(this typeof Param, value: T | null, make: (value: T) => Param): Param {
	return value == null ? Param.null() : make(value);
}

// The parameter of one field of a named-values struct; `null` binds SQL NULL.
function integerParam<T>(value: T | null): Param {
	return value == null ? Param.null() : Param.integer(value as int64);
}

function realParam(value: float64 | null): Param {
	return value == null ? Param.null() : Param.real(value);
}

function booleanParam(value: boolean | null): Param {
	return value == null ? Param.null() : Param.integer(value ? 1 : 0);
}

function textParam(value: string | null): Param {
	return value == null ? Param.null() : Param.text(value);
}

function blobParam(value: uint8[] | null): Param {
	return value == null ? Param.null() : Param.blob(value);
}

// Values for `:name`, `@name` or `$name` parameters, one per field name.
export struct Named {
	names: string[];
	params: Param[];
}

// The fields of the struct `values` as named parameters: `named({ host, busy })` binds `:host`
// and `:busy`.
export function named<P>(values: P): Named {
	return namedValues(values, null as P | null);
}
