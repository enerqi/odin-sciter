// Shared source index for the `sciter_app` checks.
//
// Every check in this package asks a question about the same thing - the declarations of
// `package sciter_app` - so the package is collected and parsed once and each check reads the index
// that comes out. That is the whole reason these are one binary with subcommands rather than six
// programs: six Python processes each re-read and re-scan the tree.
//
// **Why an AST and not a regex.** These replace six scripts under `.github/scripts` - `check-ownership`,
// `check-affinity`, `check-invariants`, `check-api-coverage`, `check-doc-ownership`, `parity` and
// `stats` - which are deleted; two implementations of one rule is the drift these checks exist to
// prevent. They are named throughout the comments here because what they got wrong is the argument for
// the rewrite, and `git log` is where to read them.
//
// The Python originals hand-rolled four partial parsers between them -
// `split_signature` (paren matching), `split_top_level` (comma splitting), `definitions` (scan until a
// line ends in `{`, bail on a blank line) and `enclosing_procs` (line -> owning procedure). Each is a
// piece of a parser written badly on purpose, and each carries a comment about the case it gets wrong.
// `core:odin/parser` is the same parser the compiler front end and ols use, so the questions those
// four were approximating - what are this procedure's parameters, what does it return, where does its
// body end, what does it call - are field accesses here.
//
// The one thing the AST does *not* give is types. `core:odin/parser` is syntax only: no name
// resolution, no cross-package lookup, no inference. So "does this procedure transitively reach
// `tracked()`" is still a syntactic call-graph walk, exactly as it was in Python - just over
// `Call_Expr` nodes rather than a regex that also matches `if (`, a type conversion and the inside of
// a comment.
//
// ---------------------------------------------------------------------------------------------------
// A short tour of `core:odin/ast`, because nothing else in this repository uses it
// ---------------------------------------------------------------------------------------------------
//
// **Every node is a struct with an embedded base.** `ast.Node` carries `pos`, `end` (both
// `tokenizer.Pos`, which has a byte `offset` as well as line/column) and a tagged union naming the
// concrete type. `ast.Expr` and `ast.Stmt` embed `Node` and add a union of their own. So a node is
// always reached as a pointer - `^ast.Call_Expr`, `^ast.Value_Decl` - and never by value.
//
// **There are three union fields, and picking the wrong one is the usual first mistake.**
//
//	n.derived        on any ^ast.Node  - Any_Node, the widest: every node type
//	e.derived_expr   on any ^ast.Expr  - Any_Expr, expressions only
//	s.derived_stmt   on any ^ast.Stmt  - Any_Stmt, statements and declarations only
//
// They are unions of *pointers*, so the switch arms are `case ^ast.Ident:` and the bound variable is
// already the pointer. When you hold a `^ast.Expr` and want to know what it is, use `derived_expr`;
// when a generic walk hands you a `^ast.Node`, use `derived`. Both work through the embedded base, so
// `some_call_expr.pos` reads the `Node` field directly.
//
// **Traversal is `ast.walk` plus an `ast.Visitor`.** The visitor is a struct of two fields: a `visit`
// procedure and a `data: rawptr`. `walk` calls `visit(v, node)`; if it returns non-nil, `walk`
// recurses into that node's children with the returned visitor and then calls `visit` once more with a
// nil node. Returning nil prunes the subtree. Odin has no closures, so the way to give `visit` state
// is the pattern used throughout this package: declare a struct whose *first* field is the
// `ast.Visitor`, point `visitor.data` at the struct itself, and cast `v.data` back inside the
// callback. `visit` is written as a procedure literal with no captures, which is why it has to be.
//
// **Source text comes from offsets, not from a printer.** `ast.File.src` is the whole file and every
// node's `pos.offset`/`end.offset` index into it, so `node_text` below hands back the exact bytes the
// node was parsed from. That matters for the checks that compare a *spelling* - `^Value` is not
// `Value`, `cstring` is not `string` - where a resolved type would be the wrong question and a
// pretty-printer would be a second thing that can disagree with the file.
package checks

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// A top-level `name :: proc` declaration.
//
// Procedure *groups* (`state :: proc { window_state, element_state }`) are in here with `lit == nil`
// and `type == nil`. They have to be: a group is a name a caller writes and therefore a name
// docs/api.md must document, and there are four of them - `draw_rounded_rect`, `state`, `set_state`
// and `value_from`. They are also the four names the first AST version of this dropped, because
// `proc {` is a `Proc_Group` and not a `Proc_Lit`. Checks that read a signature skip them for free by
// testing `type == nil`; checks that count the API surface must not.
//
// Procedure *types* are not here at all. `Asset_Call :: proc(result: Value, ok: bool)` declares a
// callback type and defines nothing, which is the distinction `check-invariants.py`'s `definitions()`
// was making by scanning for a line that ends in `{` and giving up at a blank line. The parser makes
// it structurally: a type is a `Proc_Type` value, not a `Proc_Lit`.
//
// `lit != nil && lit.body == nil` is a foreign declaration.
Proc_Info :: struct {
	name:    string,
	file:    string, // repository-relative, forward slashes
	line:    int,
	src:     string, // the whole file, so any node can be quoted verbatim
	decl:    ^ast.Value_Decl,
	lit:     ^ast.Proc_Lit, // nil for a procedure group
	group:   ^ast.Proc_Group, // nil for an ordinary procedure
	type:    ^ast.Proc_Type, // nil for a procedure group
	private: bool, // @(private) or @(private = "file"), in any attribute group
}

// One parsed file. `src` is duplicated out of `file.src` only so the common case - "quote this node" -
// does not need the `^ast.File` in hand.
Source_File :: struct {
	path: string, // repository-relative, forward slashes
	src:  string,
	file: ^ast.File,
}

Index :: struct {
	files:   []Source_File,
	procs:   []Proc_Info, // sorted by (file, line)
	by_name: map[string]int, // name -> index into `procs`; last declaration wins, as Python's dict did
}

// The text a node was parsed from.
//
// `tokenizer.Pos` is `{file, offset, line, column}` and `offset` is a plain byte index from the start
// of the file, so a node's source is a substring of `ast.File.src`. Every node has both a `pos` (its
// first byte) and an `end` (one past its last), inherited from the embedded `ast.Node`.
//
// Clamped rather than trusted: a synthesised node - one the parser inserted while recovering from a
// syntax error - can carry a zeroed or out-of-range position, and the fragment checker parses text
// that is *expected* to fail sometimes.
node_text :: proc(src: string, pos, end: tokenizer.Pos) -> string {
	lo := clamp(pos.offset, 0, len(src))
	hi := clamp(end.offset, lo, len(src))
	return src[lo:hi]
}

// The same for an expression, which is the common case: a type in a signature is an `^ast.Expr`, and
// what these checks want from it is how it was written.
expr_text :: proc(src: string, e: ^ast.Expr) -> string {
	if e == nil {
		return ""
	}
	// `e.pos`/`e.end` resolve through `ast.Expr`'s embedded `using expr_base: Node`.
	return node_text(src, e.pos, e.end)
}

// A `parser.Error_Handler`/`Warning_Handler` that says nothing.
//
// `parser.default_parser()` installs handlers that print to stderr, which is right for the package -
// a syntax error in a file this repository owns is a real failure and should be loud - and wrong for
// the doc-comment listings, where a fragment that does not parse is an ordinary outcome and printing
// it would bury the findings.
silent_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}

// Parse a standalone string of Odin. `ok` is false when it did not parse.
//
// `parser.parse_file` takes a `^ast.File` that the caller has already filled in - it does no I/O of
// its own, it only needs `src` (and `fullpath`, which it copies into every position for error
// messages). `ast.new(T, pos, end)` is the allocator the AST uses throughout; it returns a zeroed `^T`
// with the base `Node` positions set.
//
// Two failure signals, and both are needed: `parse_file` returns false only for the failures it
// cannot recover from, while `file.syntax_error_count` counts every error the handler was called
// with. A fragment that is *almost* Odin comes back with `parsed == true` and a non-zero count.
parse_source :: proc(name, src: string) -> (file: ^ast.File, ok: bool) {
	file = ast.new(ast.File, tokenizer.Pos{}, tokenizer.Pos{})
	file.fullpath = name
	file.src = src

	p := parser.default_parser()
	p.err = silent_handler
	p.warn = silent_handler

	parsed := parser.parse_file(&p, file)
	return file, parsed && file.syntax_error_count == 0
}

repo_relative :: proc(path: string, allocator := context.allocator) -> string {
	cwd, cwd_err := os.get_working_directory(context.temp_allocator)
	if cwd_err != nil {
		return slashed(path, allocator)
	}
	rel, err := filepath.rel(cwd, path, context.temp_allocator)
	if err != nil {
		return slashed(path, allocator)
	}
	return slashed(rel, allocator)
}

// Findings are printed as `path:line:`, and a reader pastes that into an editor. One separator, so
// the output of a check does not depend on which platform CI ran it.
slashed :: proc(path: string, allocator := context.allocator) -> string {
	out, _ := strings.replace_all(path, "\\", "/", allocator)
	return out
}

// The bare names of every attribute on a declaration.
//
// `Value_Decl.attributes` is a `[dynamic]^ast.Attribute` - dynamic because the parser appends to it
// lazily - with one entry per `@(...)` group. A declaration can carry several groups:
//
//	@(private)
//	@(deferred_out = release_scoped_element)
//	scoped_make_element :: proc(...)
//
// and one group can carry several elements: `@(private, deferred_out = end_callback_temp)`. So the
// names live two levels down, in `attribute.elems`, and an element is one of two shapes - a bare
// `ast.Ident` (`private`, `test`) or an `ast.Field_Value` (`private = "file"`), whose `field` is the
// name and whose `value` is the argument. Only the name is wanted here.
//
// `#partial switch` because `Any_Expr` has some seventy members and this cares about two; without
// `#partial` Odin requires every case to be handled.
//
// This structure is why the AST version does not repeat the Python originals' rule of "`@(private)` on
// the line immediately before". That rule reads a stacked `@(private)` + `@(deferred_out = ...)` pair
// as public, because the line immediately before the declaration is the second attribute.
@(private = "file")
attribute_names :: proc(decl: ^ast.Value_Decl, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for attr in decl.attributes {
		for elem in attr.elems {
			#partial switch e in elem.derived_expr {
			case ^ast.Ident:
				append(&out, e.name)
			case ^ast.Field_Value:
				if id, ok := e.field.derived_expr.(^ast.Ident); ok {
					append(&out, id.name)
				}
			}
		}
	}
	return out[:]
}

has_attribute :: proc(decl: ^ast.Value_Decl, name: string) -> bool {
	for n in attribute_names(decl, context.temp_allocator) {
		if n == name {
			return true
		}
	}
	return false
}

// Parse an Odin package directory into the shared index.
//
// `core:odin/parser` splits this into two calls on purpose. `collect_package` does the I/O - globs
// `<dir>/*.odin`, reads each one, and hands back an `^ast.Package` whose `files` map is keyed by
// absolute path with `src` filled in and nothing parsed. `parse_package` then runs the parser over
// each file, filling in `decls`, `imports` and `comments`, and checks that they all declare the same
// package name.
//
// Error handling is by callback, not by return: `parser.default_parser()` installs handlers that print
// `file(line:col): message` to stderr, and the boolean return says only whether every file parsed. The
// default handlers are kept here - `package sciter_app` failing to parse is not a finding to report,
// it is a broken tree, and the reader wants the compiler's own wording for it.
load_index :: proc(dir: string) -> (idx: Index, ok: bool) {
	pkg, collected := parser.collect_package(dir)
	if !collected {
		fmt.eprintfln("cannot collect package at %s", dir)
		return
	}

	p := parser.default_parser()
	if !parser.parse_package(pkg, &p) {
		fmt.eprintfln("package %s did not parse", dir)
		return
	}

	// `pkg.files` is a map, so iteration order is unspecified. Sorting by path is what makes two runs
	// on the same tree - and a run on Linux against a run on Windows - report findings in the same
	// order.
	files := make([dynamic]Source_File)
	for _, f in pkg.files {
		append(&files, Source_File{path = repo_relative(f.fullpath), src = f.src, file = f})
	}
	slice.sort_by(files[:], proc(a, b: Source_File) -> bool {return a.path < b.path})

	procs := make([dynamic]Proc_Info)
	for sf in files {
		// `File.decls` is the file's top-level declarations as `[]^ast.Stmt` - the parser does not give
		// declarations a list of their own, because at file scope a declaration *is* the statement.
		for decl in sf.file.decls {
			// `derived_stmt` is the `Any_Stmt` view. `or_continue` is Odin's postfix form of "if the
			// type assertion failed, skip this iteration"; it works because a `.(T)` assertion has an
			// optional second `ok` result.
			vd := decl.derived_stmt.(^ast.Value_Decl) or_continue

			// One `Value_Decl` covers both `::` and `:=`, and both `a, b := 1, 2` and `x :: 1` - hence
			// `names` and `values` being parallel slices. `is_mutable` is the `:=` / `::` bit. A `:=` at
			// file scope is a variable and no check here is about those; more than one name means a
			// multiple declaration, which no procedure declaration is.
			if vd.is_mutable || len(vd.names) != 1 || len(vd.values) != 1 {
				continue
			}
			// The name side is an expression too (it can be `_`), so it has to be asserted to an Ident.
			ident := vd.names[0].derived_expr.(^ast.Ident) or_continue

			info := Proc_Info {
				name    = ident.name,
				file    = sf.path,
				line    = vd.pos.line,
				src     = sf.src,
				decl    = vd,
				private = has_attribute(vd, "private"),
			}
			// What is on the right of the `::` decides what kind of declaration this is, and this is
			// where the parser draws the distinction the Python `definitions()` was approximating with
			// a brace scan:
			//
			//	foo :: proc(x: int) { ... }   ^ast.Proc_Lit    a definition; `lit.body` is the block
			//	foo :: proc(x: int) -> T ---  ^ast.Proc_Lit    foreign; `lit.body` is nil
			//	foo :: proc { a, b }          ^ast.Proc_Group  an overload set; no signature, no body
			//	Foo :: proc(x: int) -> T      ^ast.Proc_Type   a *type*; declares nothing callable
			//	Foo :: struct { ... }         ^ast.Struct_Type and so on for every other kind
			//
			// The default arm drops everything that is not a procedure - types, structs, enums,
			// constants - which is most of a file and none of this tool's business.
			#partial switch v in vd.values[0].derived_expr {
			case ^ast.Proc_Lit:
				info.lit = v
				info.type = v.type // ^ast.Proc_Type: calling convention, params, results
			case ^ast.Proc_Group:
				info.group = v
			case:
				continue
			}
			append(&procs, info)
		}
	}
	slice.sort_by(procs[:], proc(a, b: Proc_Info) -> bool {
		if a.file != b.file {
			return a.file < b.file
		}
		return a.line < b.line
	})

	by_name := make(map[string]int)
	for pi, i in procs {
		by_name[pi.name] = i
	}

	return Index{files = files[:], procs = procs[:], by_name = by_name}, true
}

// --- signature helpers ---------------------------------------------------------------------------
//
// `ast.Proc_Type` holds the whole signature: `calling_convention`, `params` and `results`, the last
// two being `^ast.Field_List`. A `Field_List` is `{open, list: []^Field, close}` and a `Field` is
// `{names: []^Expr, type: ^Expr, default_value, ...}` - so one `Field` covers `a, b: Element`, with
// two names against one type. Both lists are nil when absent: a procedure with no parameters has
// `params == nil`, and one that returns nothing has `results == nil`.
//
// This grouping is exactly what the Python `split_signature` was reconstructing by matching parens to
// find where the parameters ended, and what `split_top_level` was reconstructing by splitting on
// commas that were not inside brackets. Here it is already done, and the only work left is flattening
// one `Field` with two names back into two entries so that positions line up with call arguments.
//
// Results are a `Field_List` too, which is why `-> (v: Value, ok: bool)` and `-> Value` need no
// special-casing between them: the second is a one-`Field` list with no names.

// One entry per declared parameter *name*, in order, so positional arguments line up.
param_types :: proc(pi: Proc_Info, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	// nil for a procedure group, which has no signature at all.
	if pi.type == nil || pi.type.params == nil {
		return out[:]
	}
	for field in pi.type.params.list {
		text := expr_text(pi.src, field.type)
		// `max(..., 1)` because an unnamed parameter - `proc(int)` - is a Field with a type and no
		// names, and it still occupies a position.
		n := max(len(field.names), 1)
		for _ in 0 ..< n {
			append(&out, text)
		}
	}
	return out[:]
}

// The declared parameter names, in order. Used to answer "does this take an allocator", which the
// ownership rule is written in terms of.
param_names :: proc(pi: Proc_Info, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if pi.type == nil || pi.type.params == nil {
		return out[:]
	}
	for field in pi.type.params.list {
		for name in field.names {
			if id, ok := name.derived_expr.(^ast.Ident); ok {
				append(&out, id.name)
			}
		}
	}
	return out[:]
}

// The spelling of each result type, in order. `-> (v: Value, ok: bool)` yields {"Value", "bool"}.
result_types :: proc(pi: Proc_Info, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if pi.type == nil || pi.type.results == nil {
		return out[:]
	}
	for field in pi.type.results.list {
		text := expr_text(pi.src, field.type)
		n := max(len(field.names), 1)
		for _ in 0 ..< n {
			append(&out, text)
		}
	}
	return out[:]
}

// The calling convention as a bare word: `system`, `c`, `contextless`, or "" for the Odin default.
//
// `ast.Proc_Calling_Convention` is a union of `string` and `Proc_Calling_Convention_Extra`. The string
// arm is stored **with its quotes** - `parser.string_to_calling_convention` returns the token text
// unchanged, so the value is literally `"system"` including the two `"` bytes - and the union is nil
// when the procedure declared none. Trimming both quote characters covers the backtick form the
// language also accepts.
calling_convention :: proc(pi: Proc_Info) -> string {
	if pi.type == nil {
		return ""
	}
	s, ok := pi.type.calling_convention.(string)
	if !ok {
		return ""
	}
	return strings.trim(s, "\"`")
}

// --- call graph ----------------------------------------------------------------------------------
//
// The visitor-with-state pattern, used four times in this package and once more in each of
// `invariants.odin` and `doc_ownership.odin`.
//
// `ast.walk(v, node)` calls `v->visit(node)`, and if that returns non-nil it recurses into the node's
// children and then calls `visit(nil)` to signal the end. Returning nil prunes the subtree; these
// collectors always want the whole tree, so they always return `v` and ignore the nil call.
//
// `visit` is a bare procedure pointer and Odin has no closures, so state has to travel through
// `Visitor.data: rawptr`. The idiom: declare a struct whose **first field** is the `ast.Visitor`,
// point `visitor.data` at the struct, and cast `v.data` back to that struct inside the callback. The
// first-field placement is not required by `walk` - `data` is what it actually reads - but it keeps
// `&c.visitor` and `&c` the same address, which makes the round trip obviously sound.
@(private = "file")
Call_Collector :: struct {
	visitor: ast.Visitor,
	names:   ^[dynamic]string,
}

// Every identifier in callee position inside `node`.
//
// `ast.Call_Expr` is `{expr, args, ...}` where `expr` is whatever is being called. Two shapes matter:
// a bare `^ast.Ident` (`foo(x)`) and a `^ast.Selector_Expr` (`pkg.foo(x)`, `engine().SciterFoo(x)`),
// whose `field` is the name after the dot. A selector's own `expr` may itself contain a call, and
// `walk` reaches it separately, so `engine().SciterFoo(x)` contributes both names.
//
// `Type(x)` yields "Type": a conversion is a call syntactically, and without type information the
// parser cannot tell one from the other. That is the one place this is no better than the regex it
// replaces. It *is* better in that `if (`, `for (`, a comment and a string literal are no longer
// calls - which the regex `\b([a-z_][a-z_0-9]*)\s*\(` counted as three more.
callee_idents :: proc(node: ^ast.Node, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	c := Call_Collector {
		names = &names,
	}
	c.visitor.data = &c
	c.visitor.visit = proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
		if n == nil {
			return v
		}
		self := (^Call_Collector)(v.data)
		if call, ok := n.derived.(^ast.Call_Expr); ok {
			#partial switch callee in call.expr.derived_expr {
			case ^ast.Ident:
				append(self.names, callee.name)
			case ^ast.Selector_Expr:
				if callee.field != nil {
					append(self.names, callee.field.name)
				}
			}
		}
		return v
	}
	ast.walk(&c.visitor, node)
	return names[:]
}

// A call, and the verbatim spelling of what is being called: `engine`, `sciter.api`,
// `graphics_api().gRoundedRectangle`. The spelling is what the checks want - none of them can resolve
// a name anyway, and comparing text against text keeps the rule readable next to the prose that
// states it.
//
// `pos` is the call's own start, which is what a finding prints as `file:line`. `tokenizer.Pos`
// carries `line` alongside `offset`, so no line counting is needed anywhere in this package.
Call_Site :: struct {
	callee: string,
	pos:    tokenizer.Pos,
}

@(private = "file")
Site_Collector :: struct {
	visitor: ast.Visitor,
	sites:   ^[dynamic]Call_Site,
	src:     string,
}

// Every call in `node`, spelled as written. Unlike `callee_idents` this keeps the whole callee
// expression rather than the last name, because `affinity` has to tell `sciter.api()` - the unguarded
// route - from `engine()`, the guarded one, and both end in a name that means nothing on its own.
collect_calls :: proc(node: ^ast.Node, src: string, allocator := context.allocator) -> []Call_Site {
	sites := make([dynamic]Call_Site, allocator)
	c := Site_Collector {
		sites = &sites,
		src   = src,
	}
	c.visitor.data = &c
	c.visitor.visit = proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
		if n == nil {
			return v
		}
		self := (^Site_Collector)(v.data)
		if call, ok := n.derived.(^ast.Call_Expr); ok && call.expr != nil {
			append(self.sites, Call_Site{callee = expr_text(self.src, call.expr), pos = call.pos})
		}
		return v
	}
	ast.walk(&c.visitor, node)
	return sites[:]
}

@(private = "file")
Attr_Counter :: struct {
	visitor: ast.Visitor,
	name:    string,
	count:   ^int,
}

// How many declarations anywhere in `node` carry `@(<name>)`.
//
// Anywhere, not just at file scope, and that is the whole point: five of the example suite's `@(test)`
// procedures sit inside `when ODIN_OS != .Windows { ... }` blocks, guarding around the Odin test
// runner's Windows behaviour. A `when` at file scope is an `ast.When_Stmt` holding a `Block_Stmt`, so
// those declarations are not in `File.decls` at all - they are two levels down. A scan of top-level
// declarations counts 401 of 406 and reports it as the truth, which is the failure mode this number
// exists to prevent. `ast.walk` goes everywhere, so this does not have to know about `when` at all.
count_attributed_decls :: proc(node: ^ast.Node, name: string) -> int {
	count := 0
	c := Attr_Counter {
		name  = name,
		count = &count,
	}
	c.visitor.data = &c
	c.visitor.visit = proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
		if n == nil {
			return v
		}
		self := (^Attr_Counter)(v.data)
		if vd, ok := n.derived.(^ast.Value_Decl); ok && has_attribute(vd, self.name) {
			self.count^ += 1
		}
		return v
	}
	ast.walk(&c.visitor, node)
	return count
}

@(private = "file")
Field_Collector :: struct {
	visitor: ast.Visitor,
	names:   ^map[string]bool,
}

// Every `.field` written anywhere in `node`, as a set.
//
// This is what `parity` and `stats` were asking with `\.name\b` over the concatenated text of every
// file: which wrappers does the example suite touch, which C-API slots does the package reach. Both
// deliberately match a *mention* rather than a call, because a wrapper is as often stored or
// forwarded as invoked - `\.name(` undercounts, and this repository has been bitten by that. A
// `Selector_Expr` is the same rule with the same breadth, minus the mentions that were inside a
// comment or a string literal.
selector_fields :: proc(node: ^ast.Node, into: ^map[string]bool) {
	c := Field_Collector {
		names = into,
	}
	c.visitor.data = &c
	c.visitor.visit = proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
		if n == nil {
			return v
		}
		self := (^Field_Collector)(v.data)
		#partial switch sel in n.derived {
		case ^ast.Selector_Expr:
			// `a.b` - `expr` is `a`, `field` is `b`.
			if sel.field != nil {
				self.names[sel.field.name] = true
			}
		case ^ast.Implicit_Selector_Expr:
			// `.b`, the enum/bit-set shorthand. A different node with no left-hand side, and it has to
			// be here or `.CHECKED` and friends go uncounted.
			if sel.field != nil {
				self.names[sel.field.name] = true
			}
		}
		return v
	}
	ast.walk(&c.visitor, node)
}

// Which procedure a byte offset falls inside, or nil at file scope.
//
// A declaration's `pos`/`end` span the whole thing, body included, and top-level declarations do not
// overlap - so "is this call inside that procedure" is one range test. This is the whole of what
// `check-affinity.py`'s `enclosing_procs` was reconstructing: it built a line -> name map by finding
// every column-0 `name :: proc` with a regex and assuming each one owned every line up to the next.
enclosing_proc :: proc(idx: ^Index, file: string, offset: int) -> ^Proc_Info {
	for &pi in idx.procs {
		if pi.file != file {
			continue
		}
		if offset >= pi.decl.pos.offset && offset < pi.decl.end.offset {
			return &pi
		}
	}
	return nil
}

// Does `name` reach any of `targets`, directly or through other procedures of the package?
//
// Delegation has to be followed or every `scoped_` twin and every wrapper reads as a hole - measured
// at 40 false positives against 8 real questions when it was not.
//
// Syntactic, and it cannot be otherwise: `core:odin/parser` resolves no names, so "calls `tracked`"
// means "writes the token `tracked` in callee position somewhere in the body". What that buys over the
// regex it replaces is that a mention in a *comment* is no longer a call - and that is not a small
// distinction here. `check-invariants.py` took a procedure's body to be every line from its
// declaration to the next column-0 declaration, which swept up the doc comment written above the next
// procedure. `value_owns_reference` is immediately followed by the comment above `tracked`, which
// reads "a producer reads `return tracked(v), nil`" - so the regex found a call to `tracked` inside
// `value_owns_reference`, and every caller of `value_clear` inherited a path to the ledger that does
// not exist. Four procedures passed on that basis. Here `pi.lit.body` is the block and nothing else.
//
// `seen` is threaded by the caller rather than defaulted, so one query's cycle-breaking cannot leak
// into the next. Breadth first over the direct calls before recursing, so the cheap answer wins.
reaches :: proc(idx: ^Index, name: string, targets: map[string]bool, seen: ^map[string]bool) -> bool {
	if name in seen^ {
		return false
	}
	i, found := idx.by_name[name]
	if !found {
		return false // not ours - a builtin, an import, or a type conversion
	}
	seen[name] = true

	pi := idx.procs[i]
	// A procedure group or a foreign declaration: nothing to look inside.
	if pi.lit == nil || pi.lit.body == nil {
		return false
	}
	// `Proc_Lit.body` is a `^ast.Stmt` (a `Block_Stmt` in practice). `ast.walk` wants a `^ast.Node`,
	// and `Stmt` embeds its base as `using stmt_base: Node` - so `&body.stmt_base` is the way to get
	// one. There is no `.node` field to take the address of; the embedded field's own name is what is
	// addressable.
	called := callee_idents(&pi.lit.body.stmt_base, context.temp_allocator)
	for c in called {
		if c == name {
			continue
		}
		if c in targets {
			return true
		}
	}
	for c in called {
		if c == name {
			continue
		}
		if reaches(idx, c, targets, seen) {
			return true
		}
	}
	return false
}

// --- documented exemptions -----------------------------------------------------------------------
//
// Each entry is a deliberate act and the reason is the value, which is the shape the Python tables
// had. A plain array rather than a map: four to six entries make lookup cost nothing, the order is
// the order somebody wrote them in, and an array literal needs no `#+feature dynamic-literals` and no
// allocation at startup. Every table is checked for entries that no longer apply - a list nothing
// prunes rots into a list nobody trusts.
Exemption :: struct {
	name:   string,
	reason: string,
}

exempt :: proc(list: []Exemption, name: string) -> bool {
	for e in list {
		if e.name == name {
			return true
		}
	}
	return false
}

// --- small shared utilities ----------------------------------------------------------------------

read_file :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	data, err := os.read_entire_file(path, allocator)
	return string(data), err == nil
}

set_of :: proc(names: []string, allocator := context.allocator) -> map[string]bool {
	m := make(map[string]bool, allocator)
	for n in names {
		m[n] = true
	}
	return m
}

// A whole-word search, the equivalent of the `\bname\b` the Python checks lean on for prose.
contains_word :: proc(haystack, word: string) -> bool {
	if len(word) == 0 {
		return false
	}
	rest := haystack
	base := 0
	for {
		i := strings.index(rest, word)
		if i < 0 {
			return false
		}
		at := base + i
		before_ok := at == 0 || !is_word_byte(haystack[at - 1])
		after := at + len(word)
		after_ok := after >= len(haystack) || !is_word_byte(haystack[after])
		if before_ok && after_ok {
			return true
		}
		rest = rest[i + 1:]
		base = at + 1
	}
}

is_word_byte :: proc(c: u8) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
