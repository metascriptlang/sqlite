import { Node, error } from "std/meta";

// Stops a JS build at the call: the driver binds the native SQLite library.
export macro nativeOnly(site: Node): Node {
	error("sqlite is a native driver: --target=js is not supported", site);
	return site;
}
