// A real library, bound and published to script: SQLite as a Sciter extension.
//
//   just extension sqlite_extension        # builds target/debug/odin-sqlite.so
//   odin test examples/sqlite_extension.odin -file
//
// [`extension.odin`](./extension.odin) proves the *mechanism* - one exported `SciterLibraryInit`, three
// functions, forty lines. This is the same mechanism at the size of the thing people actually write:
// the SDK's own `sciter-sqlite`, which is three SOM classes (`SQLite`, `DB`, `Recordset`) with real
// object lifetimes behind them. That is the reference this file is measured against, and it is stage 5
// of [`SDK-PARITY.md`](../docs/SDK-PARITY.md#stage-5--the-long-tail).
//
//	// in a document loaded by scapp, with odin-sqlite.so beside it:
//	import * as sciter from "@sciter";
//	const SQLite = sciter.loadLibrary("odin-sqlite").SQLite;
//
//	const db = SQLite.open(":memory:");
//	db.exec("create table t(a integer, b text)");
//	db.exec("insert into t values(?, ?)", 1, "one");
//	const rs = db.exec("select a, b from t");
//	while (rs.isValid) { console.log(rs.field(0), rs.field(1)); rs.next(); }
//
// **Four things this teaches that the small extension cannot:**
//
//   - **Objects, not functions.** `SciterLibraryInit` can only hand back one Value, so everything else
//     has to hang off it. Here that Value is a map holding one asset - the `SQLite` class - and the
//     other two classes are reached only by *calling* it: `open` returns a `DB` asset, `exec` returns a
//     `Recordset` asset. An asset returned from a method is how a native library grows an object graph.
//   - **Lifetimes have to be decided, not inherited.** Script can drop the last reference to a
//     recordset at any point, and the engine will not tell you. This file's answer is the one the SDK's
//     own binding uses: a statement is finalised by `close`, by exhausting it, or by its `DB` closing -
//     and a closed handle answers "invalid" rather than crashing. See `Db` and `Recordset` below.
//   - **The library is loaded at runtime, not linked.** `libsqlite3.so.0` is opened with
//     `dynlib.load_library` and its symbols taken one by one, exactly as `package sciter` does for the
//     engine itself. That means **no `-lsqlite3`, no `sqlite3.h`, and no development package** - the
//     runtime library that is already on the machine is enough, and a machine without it gets a clean
//     error instead of a link failure. Distributions ship `libsqlite3.so.0`; only `-dev` packages ship
//     the `.so` symlink a linker needs.
//   - **Errors are the interface.** Half of a real binding is deciding what script sees when the
//     library says no. Every method here either returns a value or throws, and the thrown text is
//     SQLite's own `sqlite3_errmsg`.
//
// The Odin side is testable without the engine at all, which is the other reason to structure it this
// way: `Sqlite`, `Db` and `Statement` know nothing about Sciter, and the tests at the bottom drive them
// directly.
package odin_sqlite_extension

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------------------------------
// The library, opened at runtime
//
// One struct of procedure pointers, filled by `dynlib.initialize_symbols` from the names in the tags.
// This is the same arrangement `package sciter` uses for libsciter, and it is why nothing here needs a
// header or a link flag.

Sqlite_Api :: struct {
	sqlite3_libversion:        proc "c" () -> cstring,
	sqlite3_open_v2:           proc "c" (filename: cstring, db: ^rawptr, flags: c.int, vfs: cstring) -> c.int,
	sqlite3_close_v2:          proc "c" (db: rawptr) -> c.int,
	sqlite3_errmsg:            proc "c" (db: rawptr) -> cstring,
	sqlite3_prepare_v2:        proc "c" (db: rawptr, sql: cstring, n: c.int, stmt: ^rawptr, tail: ^cstring) -> c.int,
	sqlite3_step:              proc "c" (stmt: rawptr) -> c.int,
	sqlite3_finalize:          proc "c" (stmt: rawptr) -> c.int,
	sqlite3_reset:             proc "c" (stmt: rawptr) -> c.int,
	sqlite3_column_count:      proc "c" (stmt: rawptr) -> c.int,
	sqlite3_column_name:       proc "c" (stmt: rawptr, col: c.int) -> cstring,
	sqlite3_column_type:       proc "c" (stmt: rawptr, col: c.int) -> c.int,
	sqlite3_column_int64:      proc "c" (stmt: rawptr, col: c.int) -> i64,
	sqlite3_column_double:     proc "c" (stmt: rawptr, col: c.int) -> f64,
	sqlite3_column_text:       proc "c" (stmt: rawptr, col: c.int) -> cstring,
	sqlite3_column_bytes:      proc "c" (stmt: rawptr, col: c.int) -> c.int,
	sqlite3_column_blob:       proc "c" (stmt: rawptr, col: c.int) -> rawptr,
	sqlite3_bind_int64:        proc "c" (stmt: rawptr, index: c.int, value: i64) -> c.int,
	sqlite3_bind_double:       proc "c" (stmt: rawptr, index: c.int, value: f64) -> c.int,
	sqlite3_bind_text:         proc "c" (
		stmt: rawptr,
		index: c.int,
		text: cstring,
		n: c.int,
		destructor: rawptr,
	) -> c.int,
	sqlite3_bind_null:         proc "c" (stmt: rawptr, index: c.int) -> c.int,
	sqlite3_bind_blob:         proc "c" (
		stmt: rawptr,
		index: c.int,
		data: rawptr,
		n: c.int,
		destructor: rawptr,
	) -> c.int,
	sqlite3_last_insert_rowid: proc "c" (db: rawptr) -> i64,
	sqlite3_changes:           proc "c" (db: rawptr) -> c.int,
	// Not optional, despite every SQLite tutorial omitting it - see `load_sqlite`.
	sqlite3_initialize:        proc "c" () -> c.int,
	_handle:                   dynlib.Library,
}

// SQLite's own constants, copied rather than included - there are five of them and no header to read.
SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101
SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004
SQLITE_TRANSIENT :: ~uintptr(0) // (sqlite3_destructor_type)-1: copy the text, do not alias it

// Column types, as `sqlite3_column_type` reports them.
SQLITE_INTEGER :: 1
SQLITE_FLOAT :: 2
SQLITE_TEXT :: 3
SQLITE_BLOB :: 4
SQLITE_NULL :: 5

// The candidates, in the order they are tried. **`libsqlite3.so` - no version suffix - is the one a
// linker wants and the one only a `-dev` package installs**, so it is last: on an ordinary machine the
// versioned name is the one that exists.
//
// **`winsqlite3.dll` comes before `sqlite3.dll`, and that order is load-bearing.** A bare
// `sqlite3.dll` is resolved by the Windows loader against `PATH`, and on a developer machine that means
// some *other application's* copy - measured on this one, the first hit was
// `C:\Program Files\Amazon\AWSCLIV2\sqlite3.dll`, with Sublime Text's and Zeal's behind it. Which build
// you get is then a property of the machine's `PATH`, and they are not interchangeable: see
// `load_sqlite` for the one that crashed. `winsqlite3.dll` ships with Windows, is always present, and
// is the same library on every machine.
SQLITE_LIBRARY_NAMES :: []string {
	"libsqlite3.so.0",
	"libsqlite3.so",
	"libsqlite3.dylib",
	"libsqlite3.0.dylib",
	"winsqlite3.dll",
	"sqlite3.dll",
}

@(private)
g_sqlite: Sqlite_Api
@(private)
g_loaded: bool

// Opens the library and takes its symbols. Idempotent; false means no SQLite on this machine, which is
// a real answer rather than a crash.
//
// **`sqlite3_initialize` is called and it is not a formality.** SQLite normally initialises itself on
// the first API call, but a build compiled with `SQLITE_OMIT_AUTOINIT` does not, and then the first
// `sqlite3_open_v2` dereferences a null - measured, as an access violation with no diagnostic, on
// `C:\Program Files\Amazon\AWSCLIV2\sqlite3.dll` version 3.49.1. The identical sequence against the
// same DLL succeeds with one `sqlite3_initialize()` in front of it. On a build that does auto-init the
// call is a reference-counted no-op, so it costs nothing to always make it.
//
// This is the failure that makes the candidate list's order matter: without it, which SQLite a Windows
// machine happens to have first on `PATH` decides whether this example runs or crashes.
load_sqlite :: proc() -> bool {
	if g_loaded {
		return true
	}
	for name in SQLITE_LIBRARY_NAMES {
		count, ok := dynlib.initialize_symbols(&g_sqlite, name, "", "_handle")
		if ok && count > 0 && g_sqlite.sqlite3_open_v2 != nil {
			if g_sqlite.sqlite3_initialize != nil {
				g_sqlite.sqlite3_initialize()
			}
			g_loaded = true
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------------------------------
// The Odin binding
//
// Deliberately free of Sciter: a `Db` is a database, and the SOM layer below wraps *these*. Splitting
// it this way is what makes the tests at the bottom possible without an engine.

Db :: struct {
	handle:     rawptr,
	open:       bool,
	// Every statement this connection made, finalised or not. **The connection owns them**: script can
	// drop the last reference to a recordset whenever it likes and the engine will not say so, so the
	// only safe owner is the thing that outlives them all. `db_close` finalises, `destroy_db` frees.
	statements: [dynamic]^Statement,
}

Statement :: struct {
	db:     ^Db,
	handle: rawptr,
	// The row `step` last produced. `.Row` means the accessors are valid.
	state:  enum {
		Ready, // prepared, not stepped
		Row, // sitting on a row
		Done, // exhausted
		Closed, // finalised
	},
}

Db_Error :: struct {
	message: string, // allocated in the caller's allocator
	code:    int,
}

@(private)
last_error :: proc(db: ^Db, code: c.int, allocator := context.allocator) -> Db_Error {
	message := "sqlite: unknown error"
	if db != nil && db.handle != nil && g_sqlite.sqlite3_errmsg != nil {
		message = string(g_sqlite.sqlite3_errmsg(db.handle))
	}
	return {message = strings.clone(message, allocator), code = int(code)}
}

sqlite_version :: proc() -> string {
	if !load_sqlite() {
		return ""
	}
	return string(g_sqlite.sqlite3_libversion())
}

// Opens a database. `":memory:"` is a private in-memory one, which is what the tests use.
db_open :: proc(path: string, allocator := context.allocator) -> (db: ^Db, err: Maybe(Db_Error)) {
	if !load_sqlite() {
		return nil, Db_Error{message = strings.clone("sqlite: no libsqlite3 on this machine", allocator)}
	}
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	handle: rawptr
	code := g_sqlite.sqlite3_open_v2(c_path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
	if code != SQLITE_OK {
		// **`sqlite3_open_v2` returns a handle even when it fails**, and the message is on it - so the
		// close has to come after the message is read, not before.
		message := "sqlite: open failed"
		if handle != nil {
			message = string(g_sqlite.sqlite3_errmsg(handle))
		}
		failure := Db_Error {
			message = strings.clone(message, allocator),
			code    = int(code),
		}
		if handle != nil {
			g_sqlite.sqlite3_close_v2(handle)
		}
		return nil, failure
	}
	db = new(Db, allocator)
	db.handle = handle
	db.open = true
	db.statements = make([dynamic]^Statement, allocator)
	return db, nil
}

// Closes it, finalising every statement it still owns first. Safe twice.
db_close :: proc(db: ^Db) {
	if db == nil || !db.open {
		return
	}
	for statement in db.statements {
		if statement.state != .Closed && statement.handle != nil {
			g_sqlite.sqlite3_finalize(statement.handle)
			statement.handle = nil
			statement.state = .Closed
		}
	}
	g_sqlite.sqlite3_close_v2(db.handle)
	db.handle = nil
	db.open = false
}

destroy_db :: proc(db: ^Db, allocator := context.allocator) {
	if db == nil {
		return
	}
	db_close(db)
	for statement in db.statements {
		free(statement, allocator)
	}
	delete(db.statements)
	free(db, allocator)
}

// What a parameter can be. Values arriving from script are `sciter_app.Value`s; this is the neutral
// form the binding works in, so the SQL layer stays free of Sciter.
Db_Value :: union {
	i64,
	f64,
	string,
	[]u8,
}

// Prepares a statement and binds its parameters. The caller owns the result and must `statement_close`
// it - or let `db_close` do it.
db_prepare :: proc(
	db: ^Db,
	sql: string,
	args: []Db_Value = nil,
	allocator := context.allocator,
) -> (
	statement: ^Statement,
	err: Maybe(Db_Error),
) {
	if db == nil || !db.open {
		return nil, Db_Error{message = strings.clone("sqlite: the database is closed", allocator)}
	}
	c_sql := strings.clone_to_cstring(sql, context.temp_allocator)
	handle: rawptr
	if code := g_sqlite.sqlite3_prepare_v2(db.handle, c_sql, -1, &handle, nil); code != SQLITE_OK {
		return nil, last_error(db, code, allocator)
	}

	statement = new(Statement, allocator)
	statement.db = db
	statement.handle = handle
	statement.state = .Ready
	append(&db.statements, statement)

	// SQLite's parameter indices are 1-based, which is the sort of thing that costs an hour once.
	for arg, i in args {
		index := c.int(i + 1)
		code: c.int
		switch value in arg {
		case i64:
			code = g_sqlite.sqlite3_bind_int64(handle, index, value)
		case f64:
			code = g_sqlite.sqlite3_bind_double(handle, index, value)
		case string:
			text := strings.clone_to_cstring(value, context.temp_allocator)
			// SQLITE_TRANSIENT, so SQLite copies the text: the temp allocator will be gone by the time
			// the statement runs.
			code = g_sqlite.sqlite3_bind_text(handle, index, text, c.int(len(value)), rawptr(SQLITE_TRANSIENT))
		case []u8:
			code = g_sqlite.sqlite3_bind_blob(
				handle,
				index,
				raw_data(value),
				c.int(len(value)),
				rawptr(SQLITE_TRANSIENT),
			)
		case:
			code = g_sqlite.sqlite3_bind_null(handle, index)
		}
		if code != SQLITE_OK {
			failure := last_error(db, code, allocator)
			statement_close(statement)
			return nil, failure
		}
	}
	return statement, nil
}

// Advances to the next row. `has_row = false` with no error means the statement is exhausted, which is
// the normal end of a query and the normal *whole* result of an insert.
statement_step :: proc(
	statement: ^Statement,
	allocator := context.allocator,
) -> (
	has_row: bool,
	err: Maybe(Db_Error),
) {
	if statement == nil || statement.state == .Closed {
		return false, Db_Error{message = strings.clone("sqlite: the statement is closed", allocator)}
	}
	code := g_sqlite.sqlite3_step(statement.handle)
	switch code {
	case SQLITE_ROW:
		statement.state = .Row
		return true, nil
	case SQLITE_DONE:
		statement.state = .Done
		return false, nil
	}
	statement.state = .Done
	return false, last_error(statement.db, code, allocator)
}

statement_column_count :: proc(statement: ^Statement) -> int {
	if statement == nil || statement.state == .Closed {
		return 0
	}
	return int(g_sqlite.sqlite3_column_count(statement.handle))
}

statement_column_name :: proc(statement: ^Statement, column: int, allocator := context.allocator) -> string {
	if statement == nil || statement.state == .Closed {
		return ""
	}
	name := g_sqlite.sqlite3_column_name(statement.handle, c.int(column))
	if name == nil {
		return ""
	}
	return strings.clone(string(name), allocator)
}

// The column's value in its own type. Nil for a NULL column, and for anything read off a statement that
// is not sitting on a row - which is the case `Recordset.field` below turns into "invalid".
statement_column :: proc(statement: ^Statement, column: int, allocator := context.allocator) -> Db_Value {
	if statement == nil || statement.state != .Row {
		return nil
	}
	index := c.int(column)
	switch g_sqlite.sqlite3_column_type(statement.handle, index) {
	case SQLITE_INTEGER:
		return g_sqlite.sqlite3_column_int64(statement.handle, index)
	case SQLITE_FLOAT:
		return g_sqlite.sqlite3_column_double(statement.handle, index)
	case SQLITE_TEXT:
		text := g_sqlite.sqlite3_column_text(statement.handle, index)
		if text == nil {
			return nil
		}
		return strings.clone(string(text), allocator)
	case SQLITE_BLOB:
		n := int(g_sqlite.sqlite3_column_bytes(statement.handle, index))
		data := g_sqlite.sqlite3_column_blob(statement.handle, index)
		if data == nil || n == 0 {
			return []u8{}
		}
		out := make([]u8, n, allocator)
		runtime.mem_copy(raw_data(out), data, n)
		return out
	}
	return nil
}

statement_close :: proc(statement: ^Statement) {
	if statement == nil || statement.state == .Closed {
		return
	}
	if statement.handle != nil {
		g_sqlite.sqlite3_finalize(statement.handle)
		statement.handle = nil
	}
	statement.state = .Closed
	// Deliberately still in `db.statements`: the connection owns the memory, and freeing it here would
	// leave the recordset asset script may still hold pointing at nothing.
}

db_last_insert_rowid :: proc(db: ^Db) -> i64 {
	if db == nil || !db.open {
		return 0
	}
	return g_sqlite.sqlite3_last_insert_rowid(db.handle)
}

db_changes :: proc(db: ^Db) -> int {
	if db == nil || !db.open {
		return 0
	}
	return int(g_sqlite.sqlite3_changes(db.handle))
}

// ---------------------------------------------------------------------------------------------------
// The SOM layer: the same three classes the SDK's C++ binding publishes
//
// `SQLite` is the namespace, `DB` is a connection, `Recordset` is a running statement. The interesting
// part is that a method **returns another asset**, which is how a library with more than one kind of
// object reaches script at all.

@(private)
g_classes: struct {
	sqlite:    ^sciter_app.Asset_Class,
	db:        ^sciter_app.Asset_Class,
	recordset: ^sciter_app.Asset_Class,
}

// Everything the extension allocates that has to outlive a call. An extension has no shutdown hook, so
// this is freed only when the process ends - which is the honest arrangement, not a leak to fix.
@(private)
g_assets: [dynamic]^sciter_app.Asset

// Every asset handed to script, kept alive for the same reason and out of the same allocator: the
// engine holds the pointer and never says when it is finished with it.
@(private)
own_asset :: proc(asset: ^sciter_app.Asset) -> ^sciter_app.Asset {
	context.allocator = runtime.default_allocator()
	if g_assets == nil {
		g_assets = make([dynamic]^sciter_app.Asset)
	}
	append(&g_assets, asset)
	return asset
}

// Values crossing in and out. Script hands `Value`s; the SQL layer wants `Db_Value`s.
@(private)
to_db_value :: proc(v: ^sciter_app.Value, allocator := context.allocator) -> Db_Value {
	type, _ := sciter_app.value_type(v)
	#partial switch type {
	case .INT, .BOOL:
		n, _ := sciter_app.value_to_int(v)
		return i64(n)
	case .FLOAT:
		f, _ := sciter_app.value_to_f64(v)
		return f
	case .STRING:
		s, err := sciter_app.value_to_string(v, allocator)
		if err != nil {
			return nil
		}
		return s
	case .BYTES:
		b, err := sciter_app.value_to_bytes(v)
		if err != nil {
			return nil
		}
		return b
	}
	return nil
}

@(private)
from_db_value :: proc(value: Db_Value) -> sciter_app.Value {
	switch v in value {
	case i64:
		return sciter_app.value_from_i64(v)
	case f64:
		return sciter_app.value_from_f64(v)
	case string:
		return sciter_app.value_from_string(v)
	case []u8:
		return sciter_app.value_from_bytes(v)
	}
	return {} // undefined, which is what script sees for a NULL column
}

// `SQLite.version` - a read-only property, so script can check what it is talking to.
sqlite_version_prop :: proc(asset: ^sciter_app.Asset) -> (value: sciter_app.Value, ok: bool) {
	return sciter_app.value_from_string(sqlite_version()), true
}

// `SQLite.open(path) -> DB`. The asset it returns is a *new* object with its own class, which is the
// thing `extension.odin` never had to do.
sqlite_open_method :: proc(
	asset: ^sciter_app.Asset,
	args: []sciter_app.Value,
) -> (
	result: sciter_app.Value,
	ok: bool,
) {
	path := ":memory:"
	if len(args) > 0 {
		// The path is only needed for the length of `db_open`, so it goes in the temp allocator - the
		// database it opens is what has to survive, and that is pinned below.
		if s, err := sciter_app.value_to_string(&args[0], context.temp_allocator); err == nil {
			path = s
		}
	}
	context.allocator = runtime.default_allocator() // the DB outlives this call; script decides when it dies
	db, err := db_open(path)
	if failure, failed := err.(Db_Error); failed {
		// A thrown error rather than a null: script gets SQLite's own message, which is the whole
		// difference between a usable binding and a guessing game.
		return sciter_app.value_from_string(failure.message), false
	}
	return sciter_app.value_from_asset(
			&own_asset(sciter_app.make_asset(g_classes.db, db, runtime.default_allocator())).base,
		),
		true
}

// `db.exec(sql, ...args)` - a Recordset for a query, `true` for a statement with no rows.
db_exec_method :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	db := (^Db)(asset.user_data)
	if len(args) == 0 {
		return sciter_app.value_from_string("exec() wants a statement"), false
	}
	sql, serr := sciter_app.value_to_string(&args[0], context.temp_allocator)
	if serr != nil {
		return sciter_app.value_from_string("exec() wants a string"), false
	}

	parameters := make([dynamic]Db_Value, context.temp_allocator)
	for i in 1 ..< len(args) {
		append(&parameters, to_db_value(&args[i], context.temp_allocator))
	}

	statement, perr := db_prepare(db, sql, parameters[:], runtime.default_allocator())
	if failure, failed := perr.(Db_Error); failed {
		return sciter_app.value_from_string(failure.message), false
	}

	// **The first step happens here, not in `next`.** A statement that has not been stepped has done
	// nothing - an `insert` would not have inserted - so `exec` always advances once and the recordset
	// script receives is already sitting on its first row, exactly as the SDK's binding behaves.
	has_row, serr2 := statement_step(statement)
	if failure, failed := serr2.(Db_Error); failed {
		statement_close(statement)
		return sciter_app.value_from_string(failure.message), false
	}
	if !has_row && statement_column_count(statement) == 0 {
		// No columns at all: this was a statement rather than a query. Nothing to iterate.
		statement_close(statement)
		return sciter_app.value_from_bool(true), true
	}
	return sciter_app.value_from_asset(
			&own_asset(sciter_app.make_asset(g_classes.recordset, statement, runtime.default_allocator())).base,
		),
		true
}

db_close_method :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	db_close((^Db)(asset.user_data))
	return sciter_app.value_from_bool(true), true
}

db_last_rowid_method :: proc(
	asset: ^sciter_app.Asset,
	args: []sciter_app.Value,
) -> (
	result: sciter_app.Value,
	ok: bool,
) {
	return sciter_app.value_from_i64(db_last_insert_rowid((^Db)(asset.user_data))), true
}

db_changes_method :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	return sciter_app.value_from_int(i32(db_changes((^Db)(asset.user_data)))), true
}

// `rs.isValid` - false once the rows run out or the recordset is closed. This is the property script
// loops on, and the reason it is a property rather than a method is that the SDK's binding made the
// same call.
recordset_is_valid :: proc(asset: ^sciter_app.Asset) -> (value: sciter_app.Value, ok: bool) {
	statement := (^Statement)(asset.user_data)
	return sciter_app.value_from_bool(statement != nil && statement.state == .Row), true
}

recordset_length :: proc(asset: ^sciter_app.Asset) -> (value: sciter_app.Value, ok: bool) {
	return sciter_app.value_from_int(i32(statement_column_count((^Statement)(asset.user_data)))), true
}

recordset_next :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	statement := (^Statement)(asset.user_data)
	has_row, err := statement_step(statement)
	if failure, failed := err.(Db_Error); failed {
		return sciter_app.value_from_string(failure.message), false
	}
	if !has_row {
		// Exhausted: finalise now rather than waiting for a `close` script may never send. This is the
		// lifetime decision the header talks about.
		statement_close(statement)
	}
	return sciter_app.value_from_bool(has_row), true
}

recordset_field :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	statement := (^Statement)(asset.user_data)
	column := 0
	if len(args) > 0 {
		n, _ := sciter_app.value_to_int(&args[0])
		column = int(n)
	}
	// The Value copies whatever it is given, so the column's own memory is temporary.
	// The Value copies whatever it is given, so the column's own memory is temporary.
	return from_db_value(statement_column(statement, column, context.temp_allocator)), true
}

recordset_name :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	statement := (^Statement)(asset.user_data)
	column := 0
	if len(args) > 0 {
		n, _ := sciter_app.value_to_int(&args[0])
		column = int(n)
	}
	return sciter_app.value_from_string(statement_column_name(statement, column, context.temp_allocator)), true
}

recordset_close :: proc(asset: ^sciter_app.Asset, args: []sciter_app.Value) -> (result: sciter_app.Value, ok: bool) {
	statement_close((^Statement)(asset.user_data))
	return sciter_app.value_from_bool(true), true
}

// Builds the three classes. Separated from `SciterLibraryInit` so the tests can call it.
//
// **Everything here is allocated from the default allocator on purpose.** A passport "should be
// statically allocated - at least survive last instance of the engine", says the C header, and an
// extension has no shutdown hook to free it from. Taking `context.allocator` would tie the classes to
// whatever was current at load time - in the test runner, a per-test tracking allocator that reclaims
// them before the next test runs, which presents as an empty member list rather than as a leak report.
make_classes :: proc() -> (err: sciter_app.Error) {
	if g_classes.sqlite != nil {
		return nil
	}
	context.allocator = runtime.default_allocator()
	// **`params` is a cap on what script may pass, not a hint.** Measured on 6.0.4.9: a method declared
	// `params = 1` and called as `db.exec(sql, a, b)` receives *only* `sql` - the extra arguments are
	// dropped silently, and here that meant every bound parameter arriving as NULL and rows of nulls
	// coming back out. Declaring more than script passes is harmless, so a variadic method declares the
	// most it will ever take. `docs/api.md` carries the rule.
	g_classes.db = sciter_app.make_asset_class(
	"DB",
	nil,
	{
		{name = "exec", params = 9, call = db_exec_method}, // sql + up to eight bound parameters
		{name = "close", call = db_close_method},
		{name = "lastRowId", call = db_last_rowid_method},
		{name = "changes", call = db_changes_method},
	},
	) or_return
	g_classes.recordset = sciter_app.make_asset_class(
		"Recordset",
		{{name = "isValid", get = recordset_is_valid}, {name = "length", get = recordset_length}},
		{
			{name = "next", call = recordset_next},
			{name = "field", params = 1, call = recordset_field},
			{name = "name", params = 1, call = recordset_name},
			{name = "close", call = recordset_close},
		},
	) or_return
	g_classes.sqlite = sciter_app.make_asset_class(
		"SQLite",
		{{name = "version", get = sqlite_version_prop}},
		{{name = "open", params = 1, call = sqlite_open_method}},
	) or_return
	return nil
}

// ---------------------------------------------------------------------------------------------------
// The extension entry point
//
// One symbol, and the Value it writes is the whole public surface: a map with `SQLite` in it.

@(export)
SciterLibraryInit :: proc "system" (psapi: ^sciter.Isciter_Api, plibobject: ^sciter.Value) -> b32 {
	context = runtime.default_context()

	if err := sciter.adopt(psapi); err != .None {
		return false
	}
	if !load_sqlite() {
		// Refusing here is better than publishing an object whose every method throws.
		return false
	}
	if err := make_classes(); err != nil {
		return false
	}

	lib: sciter.Value
	root := sciter_app.value_from_asset(
		&own_asset(sciter_app.make_asset(g_classes.sqlite, nil, runtime.default_allocator())).base,
	)
	defer sciter_app.value_clear(&root)
	sciter_app.value_set(&lib, "SQLite", &root)

	plibobject^ = lib
	return true
}

// ---------------------------------------------------------------------------------------------------
// Tests
//
// The SQL layer needs no engine, so most of this runs anywhere. The SOM layer needs the engine's Value
// implementation but still no window, which is why these are the cheapest tests in the repository.

@(test)
test_the_library_loads_and_reports_a_version :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	version := sqlite_version()
	testing.expect(t, strings.contains(version, "."), "a version looks like a version")
}

@(test)
test_a_round_trip_through_a_real_database :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	db, err := db_open(":memory:")
	testing.expect(t, err == nil, "an in-memory database opens")
	if err != nil {return}
	defer destroy_db(db)

	// A statement with no rows: prepare, step once, done.
	create, cerr := db_prepare(db, "create table t(a integer, b text, c real, d blob)")
	testing.expect(t, cerr == nil)
	has_row, serr := statement_step(create)
	testing.expect(t, serr == nil)
	testing.expect(t, !has_row, "a DDL statement produces no rows")
	statement_close(create)

	// Bound parameters, one of each type this binding carries.
	insert, ierr := db_prepare(db, "insert into t values(?, ?, ?, ?)", {i64(42), "forty-two", f64(1.5), []u8{1, 2, 3}})
	testing.expect(t, ierr == nil)
	_, ierr2 := statement_step(insert)
	testing.expect(t, ierr2 == nil)
	statement_close(insert)
	testing.expect_value(t, db_last_insert_rowid(db), i64(1))

	// And back out, in the types they went in as.
	query, qerr := db_prepare(db, "select a, b, c, d from t")
	testing.expect(t, qerr == nil)
	defer statement_close(query)

	got_row, qerr2 := statement_step(query)
	testing.expect(t, qerr2 == nil)
	testing.expect(t, got_row, "the row is there")

	testing.expect_value(t, statement_column_count(query), 4)
	name := statement_column_name(query, 1, context.temp_allocator)
	testing.expect_value(t, name, "b")

	a := statement_column(query, 0, context.temp_allocator)
	integer, is_integer := a.(i64)
	testing.expect(t, is_integer, "column a came back as an integer")
	testing.expect_value(t, integer, i64(42))

	b := statement_column(query, 1, context.temp_allocator)
	text, is_text := b.(string)
	testing.expect(t, is_text, "column b came back as a string")
	testing.expect_value(t, text, "forty-two")

	c_value := statement_column(query, 2, context.temp_allocator)
	real, is_real := c_value.(f64)
	testing.expect(t, is_real, "column c came back as a float")
	testing.expect_value(t, real, f64(1.5))

	d := statement_column(query, 3, context.temp_allocator)
	blob, is_blob := d.([]u8)
	testing.expect(t, is_blob, "column d came back as bytes")
	testing.expect_value(t, len(blob), 3)

	// Exhaustion is not an error.
	more, merr := statement_step(query)
	testing.expect(t, merr == nil)
	testing.expect(t, !more, "one row means one row")
}

// The lifetime rule the header claims: a statement outlives nothing, and using a closed one answers
// rather than crashing.
@(test)
test_closing_a_database_finalises_its_statements :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	db, err := db_open(":memory:")
	testing.expect(t, err == nil)
	if err != nil {return}
	defer destroy_db(db)

	create, _ := db_prepare(db, "create table t(a integer)")
	statement_step(create)
	statement_close(create)

	insert, _ := db_prepare(db, "insert into t values(1)")
	statement_step(insert)
	statement_close(insert)

	query, qerr := db_prepare(db, "select a from t")
	testing.expect(t, qerr == nil)
	testing.expect_value(t, len(db.statements), 3) // the connection knows about all of them

	db_close(db)
	testing.expect(t, query.state == .Closed, "closing the database finalised the statement")

	// And the closed statement answers instead of faulting.
	_, serr := statement_step(query)
	testing.expect(t, serr != nil, "stepping a closed statement is an error, not a crash")
	if failure, failed := serr.(Db_Error); failed {
		delete(failure.message)
	}
	testing.expect_value(t, statement_column_count(query), 0)
	testing.expect(t, statement_column(query, 0, context.temp_allocator) == nil)

	// A second close of either is harmless.
	db_close(db)
	statement_close(query)
}

// A failure that script has to be able to see: a bad statement comes back with SQLite's own message.
@(test)
test_a_bad_statement_reports_sqlites_own_message :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	db, err := db_open(":memory:")
	testing.expect(t, err == nil)
	if err != nil {return}
	defer destroy_db(db)

	_, perr := db_prepare(db, "select * from a_table_that_does_not_exist")
	failure, failed := perr.(Db_Error)
	testing.expect(t, failed, "a bad statement fails")
	if failed {
		defer delete(failure.message)
		testing.expect(t, strings.contains(failure.message, "no such table"), "and says why, in SQLite's words")
	}
}

// The SOM half: the three classes exist, with the members the SDK's own binding publishes.
@(test)
test_the_three_classes_publish_the_expected_members :: proc(t: ^testing.T) {
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	testing.expect_value(t, make_classes(), nil)

	testing.expect_value(t, len(g_classes.sqlite.methods), 1)
	testing.expect_value(t, g_classes.sqlite.methods[0].name, "open")
	testing.expect_value(t, len(g_classes.sqlite.properties), 1)
	testing.expect_value(t, g_classes.db.methods[0].name, "exec")
	testing.expect_value(t, len(g_classes.db.methods), 4)
	testing.expect_value(t, len(g_classes.recordset.methods), 4)
	testing.expect_value(t, len(g_classes.recordset.properties), 2)
}

// **End to end, the way script sees it**: the built `.so` loaded by `sciter.loadLibrary`, driven by a
// document, with the host reading the answer back. This is the only test here that exercises
// `SciterLibraryInit` itself.
//
// It needs the shared library beside the test binary, which `just extension sqlite_extension
// odin-sqlite` puts there - so it skips itself rather than failing when only `odin test` has been run.
@(test)
test_script_can_load_the_library_and_query :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	// `DISPLAY` and `WAYLAND_DISPLAY` are X11/Wayland variables that do not exist on Windows or macOS,
	// so testing for them directly - as this did - skips the test there **silently and forever**, which
	// is the worst way for a test not to run. Every other example in this directory gates on a
	// `have_display` that answers true off Linux; this one had grown its own copy without the `when`.
	// Measured: this test printed "no DISPLAY - skipping" on the first Windows run.
	when ODIN_OS != .Windows && ODIN_OS != .Darwin {
		if os.get_env("DISPLAY", context.temp_allocator) == "" &&
		   os.get_env("WAYLAND_DISPLAY", context.temp_allocator) == "" {
			fmt.println("no DISPLAY - skipping; a windowless view still needs one")
			return
		}
	}
	// Pinned before anything allocates: the view and the assets the library makes outlive this test,
	// and the runner's per-test tracking allocator would reclaim them underneath the engine.
	context.allocator = runtime.default_allocator()

	directory := filepath.dir(os.args[0])
	defer delete(directory)
	// `.so` was hardcoded here, so on Windows this looked for `odin-sqlite.so`, never found it, and
	// skipped itself with a message that reads like the build step was forgotten. `loadLibrary` in the
	// document below takes the name *without* a suffix and appends the platform's own - which is the
	// reason the mistake is easy to make and easy to miss.
	when ODIN_OS == .Windows {
		SHARED_EXT :: ".dll"
	} else when ODIN_OS == .Darwin {
		SHARED_EXT :: ".dylib"
	} else {
		SHARED_EXT :: ".so"
	}
	library := fmt.tprintf("%s/odin-sqlite%s", directory, SHARED_EXT)
	if !os.exists(library) {
		fmt.printfln("no %s - run `just extension sqlite_extension odin-sqlite` first; skipping", library)
		return
	}

	view, err := sciter_app.create_windowless({width = 200, height = 100})
	testing.expect_value(t, err, nil)
	if err != nil {return}

	LOADER :: `<html><body><script type="module">
	  import * as sciter from "@sciter";
	  try {
	    const SQLite = sciter.loadLibrary("odin-sqlite").SQLite;
	    const db = SQLite.open(":memory:");
	    db.exec("create table t(a integer, b text)");
	    db.exec("insert into t values(?, ?)", 7, "seven");
	    const rs = db.exec("select a, b from t");
	    globalThis.answer = rs.field(0) + ":" + rs.field(1) + ":" + rs.length + ":" + SQLite.version;
	    rs.next();
	    globalThis.exhausted = !rs.isValid;
	    db.close();
	  } catch (e) {
	    globalThis.answer = "FAILED " + e;
	  }
	</script></body></html>`

	testing.expect_value(t, sciter_app.load_html(view.window, LOADER, "about:blank"), nil)
	for _ in 0 ..< 20 {
		sciter_app.windowless_heartbeat(&view, 16 * time.Millisecond)
		sciter_app.paint_windowless(&view)
	}

	answer, aerr := sciter_app.global(view.window, "answer")
	testing.expect_value(t, aerr, nil)
	defer sciter_app.value_clear(&answer)
	text, _ := sciter_app.value_to_string(&answer, context.temp_allocator)

	// 7, "seven", two columns - and SQLite's own version on the end.
	testing.expect(t, strings.has_prefix(text, "7:seven:2:"), text)
	testing.expect(t, strings.count(text, ".") >= 2, "the version came through too")

	exhausted, eerr := sciter_app.global(view.window, "exhausted")
	testing.expect_value(t, eerr, nil)
	defer sciter_app.value_clear(&exhausted)
	done, _ := sciter_app.value_to_bool(&exhausted)
	testing.expect(t, done, "one row, then the recordset finalises itself")
}

// The thing `extension.odin` could not show: a method that returns another asset, and a whole query
// driven through the SOM layer exactly as script would drive it.
@(test)
test_a_query_runs_through_the_som_layer :: proc(t: ^testing.T) {
	if !load_sqlite() {
		fmt.println("no libsqlite3 on this machine - skipping")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	testing.expect_value(t, make_classes(), nil)

	namespace := sciter_app.make_asset(g_classes.sqlite)
	defer sciter_app.destroy_asset(namespace)

	// SQLite.open(":memory:")
	path := sciter_app.value_from_string(":memory:")
	defer sciter_app.value_clear(&path)
	db_value, opened := sqlite_open_method(namespace, {path})
	testing.expect(t, opened, "open answered")
	defer sciter_app.value_clear(&db_value)

	db_asset_raw, aerr := sciter_app.value_to_asset(&db_value)
	testing.expect_value(t, aerr, nil)
	db_asset := (^sciter_app.Asset)(db_asset_raw)
	// Freed with the allocator it was made from - `sqlite_open_method` pins the connection to the
	// default one, because script decides when a database dies and the engine never says.
	defer destroy_db((^Db)(db_asset.user_data), runtime.default_allocator())

	exec :: proc(
		t: ^testing.T,
		asset: ^sciter_app.Asset,
		sql: string,
		args: ..sciter_app.Value,
	) -> (
		sciter_app.Value,
		bool,
	) {
		all := make([dynamic]sciter_app.Value, context.temp_allocator)
		statement := sciter_app.value_from_string(sql)
		append(&all, statement)
		for arg in args {
			append(&all, arg)
		}
		result, ok := db_exec_method(asset, all[:])
		sciter_app.value_clear(&statement)
		return result, ok
	}

	created, ok1 := exec(t, db_asset, "create table t(a integer, b text)")
	testing.expect(t, ok1, "create answered")
	sciter_app.value_clear(&created)

	one := sciter_app.value_from_int(1)
	defer sciter_app.value_clear(&one)
	name := sciter_app.value_from_string("one")
	defer sciter_app.value_clear(&name)
	inserted, ok2 := exec(t, db_asset, "insert into t values(?, ?)", one, name)
	testing.expect(t, ok2, "insert answered")

	// A statement with no result is `true`, not a recordset - the distinction script depends on.
	type, _ := sciter_app.value_type(&inserted)
	testing.expect(t, type != .ASSET, "an insert does not produce a recordset")
	sciter_app.value_clear(&inserted)

	changed, _ := db_changes_method(db_asset, nil)
	defer sciter_app.value_clear(&changed)
	affected, _ := sciter_app.value_to_int(&changed)
	testing.expect_value(t, affected, i32(1))

	// **`value_to_int` on this reads zero**: `lastRowId` is a `.BIG_INT`, because SQLite row ids are
	// 64-bit, and the 32-bit accessor does not convert. `value_to_i64` reads both widths - which is the
	// rule `value.odin` states and which this test got wrong first time round.
	rowid, _ := db_last_rowid_method(db_asset, nil)
	defer sciter_app.value_clear(&rowid)
	narrow, _ := sciter_app.value_to_int(&rowid)
	testing.expect_value(t, narrow, i32(0))
	n, _ := sciter_app.value_to_i64(&rowid)
	testing.expect_value(t, n, i64(1))

	// A query does produce one, already sitting on its first row.
	rs_value, ok3 := exec(t, db_asset, "select a, b from t")
	testing.expect(t, ok3, "select answered")
	defer sciter_app.value_clear(&rs_value)
	rs_raw, rerr := sciter_app.value_to_asset(&rs_value)
	testing.expect_value(t, rerr, nil)
	rs := (^sciter_app.Asset)(rs_raw)

	valid, _ := recordset_is_valid(rs)
	defer sciter_app.value_clear(&valid)
	is_valid, _ := sciter_app.value_to_bool(&valid)
	testing.expect(t, is_valid, "the recordset arrives on a row")

	column := sciter_app.value_from_int(1)
	defer sciter_app.value_clear(&column)
	field, _ := recordset_field(rs, {column})
	defer sciter_app.value_clear(&field)
	text, _ := sciter_app.value_to_string(&field, context.temp_allocator)
	testing.expect_value(t, text, "one")

	header, _ := recordset_name(rs, {column})
	defer sciter_app.value_clear(&header)
	header_text, _ := sciter_app.value_to_string(&header, context.temp_allocator)
	testing.expect_value(t, header_text, "b")

	// One row, so `next` is false - and it finalises on the way out.
	advanced, _ := recordset_next(rs, nil)
	defer sciter_app.value_clear(&advanced)
	more, _ := sciter_app.value_to_bool(&advanced)
	testing.expect(t, !more, "one row means one row here too")
	testing.expect(t, (^Statement)(rs.user_data).state == .Closed, "an exhausted recordset finalises itself")
}
