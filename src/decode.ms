// Compile-time row decoding and parameter binding: a struct type's fields become one column read
// each, checked for presence, storage class and range (a failed read is recorded on the statement,
// never defaulted), or one named parameter each.
import {
	Node,
	NodeKind,
	TypeArrayData,
	TypeGenericData,
	TypeKind,
	TypeUnionData,
	bindSym,
	error,
	getTypeImpl,
	typeKind,
} from "std/meta";

function implementationOf(type: Node): Node {
	const implementation = getTypeImpl(type);
	if (implementation == null) throw new Error("sqlite: the type has no checked implementation");
	return implementation;
}

function unwrapGeneric(type: Node): Node {
	if (type.kind != NodeKind.TypeGeneric) return type;
	if (typeKind(type) != TypeKind.GenericInstance) return (type as TypeGenericData).typExprArgs[0];
	return implementationOf(type);
}

function rowStruct(witness: Node): Node {
	let rowType = implementationOf(witness);
	if (rowType.kind == NodeKind.TypeUnion) {
		for (const member of (rowType as TypeUnionData).typExprMembers) {
			if (typeKind(member) != TypeKind.Null) rowType = implementationOf(member);
		}
	}
	return unwrapGeneric(unwrapGeneric(rowType));
}

function scalarName(kind: TypeKind): string {
	return match (kind) {
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Float64 | TypeKind.Number => "float64",
		TypeKind.Boolean => "boolean",
		TypeKind.String => "string",
		_ => "",
	};
}

// The column type name of a field (`uint8[]` for a blob, "" for none) and whether it is
// `| null`; a union of anything but one type and null has no column type.
function columnType(fieldType: Node): [string, boolean] {
	let type = implementationOf(fieldType);
	let nullable = false;
	if (type.kind == NodeKind.TypeUnion) {
		let valueMember: Node | null = null;
		let valueMembers: int32 = 0;
		for (const member of (type as TypeUnionData).typExprMembers) {
			if (typeKind(member) == TypeKind.Null) {
				nullable = true;
			} else {
				valueMember = member;
				valueMembers += 1;
			}
		}
		if (!nullable || valueMembers != 1 || valueMember == null) return ["", false];
		type = implementationOf(valueMember);
	}
	if (type.kind == NodeKind.TypeArray) {
		const element = implementationOf((type as TypeArrayData).typExprElement);
		return [typeKind(element) == TypeKind.Uint8 ? "uint8[]" : "", nullable];
	}
	return [scalarName(typeKind(type)), nullable];
}

// The field names of the row struct `T` named by `null as T | null`, in declaration order.
export macro rowFields(witness: Node): Node {
	const row = rowStruct(witness);
	if (row.kind != NodeKind.TypeObject) {
		error("sqlite: a decoded row must be a struct type", witness);
		return witness;
	}
	const names: Node[] = [];
	for (const name of row.typExprFieldNames) {
		names.push({
			kind: NodeKind.StringLiteral, line: witness.line, column: witness.column, value: name,
		});
	}
	return {
		kind: NodeKind.ArrayLiteral, line: witness.line, column: witness.column, elements: names,
	};
}

// A `T` literal reading field i from column `columns[i]` of the stepped statement `stmt`.
// The reads are built as call nodes because a quote splice as a whole call argument is not
// supported yet.
export macro rowDecode(stmt: Node, columns: Node, witness: Node): Node {
	const row = rowStruct(witness);
	if (row.kind != NodeKind.TypeObject) {
		error("sqlite: a decoded row must be a struct type", witness);
		return witness;
	}
	const line = witness.line;
	const column = witness.column;
	const int64Literal = (value: int64): Node => ({
		kind: NodeKind.NumberLiteral, line: line, column: column, value: value,
		isFloat: false, intVal: value, outOfRangeText: "", isBitPattern: false,
	});
	const read = (method: string, args: Node[]): Node => ({
		kind: NodeKind.CallExpr, line: line, column: column,
		callee: {
			kind: NodeKind.MemberExpr, line: line, column: column, object: stmt, property: method,
			isOptional: false,
		},
		arguments: args,
	});
	const keys: string[] = [];
	const values: Node[] = [];
	for (let field: int32 = 0; field < row.typExprFieldNames.length; field++) {
		const name: string = row.typExprFieldNames[field];
		const nameLit: Node = {
			kind: NodeKind.StringLiteral, line: line, column: column, value: name,
		};
		const cell: Node = {
			kind: NodeKind.ArrayAccess, line: line, column: column, array: columns,
			index: int64Literal(field as int64),
		};
		const [typeName, nullable] = columnType(row.typExprFieldTypes[field]);
		let min: int64 = 0;
		let max: int64 = 0;
		let ranged = true;
		if (typeName == "int32") {
			min = -2147483648;
			max = 2147483647;
		} else if (typeName == "int16") {
			min = -32768;
			max = 32767;
		} else if (typeName == "int8") {
			min = -128;
			max = 127;
		} else if (typeName == "uint32") {
			max = 4294967295;
		} else if (typeName == "uint16") {
			max = 65535;
		} else if (typeName == "uint8") {
			max = 255;
		} else {
			ranged = false;
		}
		let value: Node = cell;
		if (ranged) {
			value = {
				kind: NodeKind.TypeAssertion, line: line, column: column, asType: typeName,
				asExpr: read("fieldInteger", [cell, nameLit, int64Literal(min), int64Literal(max)]),
			};
		} else if (typeName == "int64") {
			value = read("fieldInt64", [cell, nameLit]);
		} else if (typeName == "float64") {
			value = read("fieldReal", [cell, nameLit]);
		} else if (typeName == "boolean") {
			value = read("fieldBoolean", [cell, nameLit]);
		} else if (typeName == "string") {
			value = read("fieldText", [cell, nameLit]);
		} else if (typeName == "uint8[]") {
			value = read("fieldBlob", [cell, nameLit]);
		} else {
			error(
				"sqlite: field '" + name + "' has no column decoding; use int8..int64, " +
					"uint8..uint32, float64, boolean, string or uint8[], optionally | null",
				witness,
			);
			return witness;
		}
		keys.push(name);
		if (nullable) {
			value = {
				kind: NodeKind.ConditionalExpr, line: line, column: column,
				ternaryCondition: read("isNull", [cell]),
				ternaryConsequent: {
					kind: NodeKind.NullLiteral, line: line, column: column, nullPlaceholder: true,
				},
				ternaryAlternate: value,
			};
		}
		values.push(value);
	}
	return {
		kind: NodeKind.ObjectLiteral, line: line, column: column,
		keys: keys, properties: values, keyLocations: [],
	};
}

// A `Named` literal for `values`, a struct named by `null as P | null`: its field names as one
// string literal and each field's parameter, built from the field's type.
export macro namedValues(values: Node, witness: Node): Node {
	const row = rowStruct(witness);
	if (row.kind != NodeKind.TypeObject) {
		error("sqlite: named values must be a struct", witness);
		return witness;
	}
	const line = witness.line;
	const column = witness.column;
	let names = "";
	const params: Node[] = [];
	for (let field: int32 = 0; field < row.typExprFieldNames.length; field++) {
		const name: string = row.typExprFieldNames[field];
		const [typeName, nullable] = columnType(row.typExprFieldTypes[field]);
		const make = match (typeName) {
			"int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" => "integerParam",
			"float64" => "realParam",
			"boolean" => "booleanParam",
			"string" => "textParam",
			"uint8[]" => "blobParam",
			_ => "",
		};
		if (make == "") {
			error(
				"sqlite: field '" + name + "' has no parameter binding; use int8..int64, " +
					"uint8..uint32, float64, boolean, string or uint8[], optionally | null",
				witness,
			);
			return witness;
		}
		names += field == 0 ? name : "," + name;
		const callee = bindSym(make);
		if (callee == null) {
			error("sqlite: the parameter builder " + make + " is not in scope", witness);
			return witness;
		}
		params.push({
			kind: NodeKind.CallExpr, line: line, column: column,
			callee: callee,
			arguments: [{
				kind: NodeKind.MemberExpr, line: line, column: column,
				object: values, property: name, isOptional: false,
			}],
		});
	}
	return {
		kind: NodeKind.ObjectLiteral, line: line, column: column, keys: ["names", "params"],
		properties: [
			{ kind: NodeKind.StringLiteral, line: line, column: column, value: names },
			{ kind: NodeKind.ArrayLiteral, line: line, column: column, elements: params },
		],
		keyLocations: [],
	};
}
