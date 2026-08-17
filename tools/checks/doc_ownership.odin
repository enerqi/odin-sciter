// Code in a comment is code nothing compiles, and this is the check for the one mistake it made.
//
// `just check` type-checks two kinds of Odin: the packages, and `docs/snippets/snippets.odin`. It does
// not type-check the third kind - the listings inside `//` doc comments in `sciter_app/*.odin` - and it
// cannot usefully be made to, because those are fragments with no declarations around them.
//
// That gap shipped a real defect. `Owned_Element` is `distinct Element`, so passing one where a
// borrowed handle is wanted does not compile; three listings did exactly that (`sciter_app/dom.odin`,
// `sciter_app/scoped.odin` and `docs/dom.md`, whose compiled twin in `snippets.odin` was correct all
// along), on the single most-copied DOM idiom in the library. A reader pasting it got
//
//	Error: Cannot assign value 'item' of type 'Owned_Element' to 'Element' in a procedure argument
//
// against prose insisting the insert does not consume the reference.
//
// So this checks the one thing about those fragments that can be checked without a full compile: the
// owned/borrowed split. Any name bound from a procedure that hands back an `Owned_*`, later passed to
// a procedure that takes the borrowed type, must go through `borrow_element` / `borrow_node` /
// `borrow_request`.
//
// **The two tables are read out of the source, not written here.** The producers are the procedures
// whose return type is an `Owned_*`, and the borrow-takers are the parameters typed `Element`, `Node`
// or `Request` - both taken from the parsed package, so adding a procedure of either kind extends this
// check without editing it.
//
// **What the AST changed, and what it did not.** Extracting the listings is still text: `//`-indented
// runs and ```odin fences are a comment convention, not Odin syntax. But *checking* a listing is no
// longer a regex that approximates assignment and argument splitting - each fragment is wrapped in a
// throwaway `package`/`proc` and handed to the real parser, so `x, err := make_element(...)` and
// `insert_element(item, list)` are an `Assign_Stmt` and a `Call_Expr` rather than two patterns that
// have to agree about where an argument ends. `split_top_level`, the hand-written comma splitter the
// Python version needed for that, is gone.
//
// A fragment that does not parse is skipped and counted. The count is printed on success for the same
// reason `stats` insists on numerals: a check that quietly stops covering things reads exactly like a
// check that is passing.
//
// What it covers:
//
//   - `//`-comment listings in sciter_app/*.odin  (the kind nothing else compiles)
//   - ```odin blocks in docs/**/*.md              (whose snippets.odin twin can drift, and did)
package checks

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

@(private = "file")
Owned_Pair :: struct {
	owned:    string,
	borrowed: string,
	cast_to:  string,
}

OWNED_TYPES := [?]Owned_Pair {
	{"Owned_Element", "Element", "borrow_element"},
	{"Owned_Node", "Node", "borrow_node"},
	{"Owned_Request", "Request", "borrow_request"},
}

// A listing: where it starts in the file it came from, and its lines with the comment marker removed.
@(private = "file")
Block :: struct {
	first_line: int,
	lines:      []string,
}

@(private = "file")
Finding :: struct {
	line: int,
	why:  string,
}

// Contiguous runs of Odin: tab-indented lines inside `//` comments, or ```odin fences.
@(private = "file")
code_blocks :: proc(path, src: string, allocator := context.allocator) -> []Block {
	blocks := make([dynamic]Block, allocator)
	lines := strings.split_lines(src, context.temp_allocator)

	if strings.has_suffix(path, ".md") {
		run := make([dynamic]string, context.temp_allocator)
		fenced := false
		start := 0
		for line, i in lines {
			if strings.has_prefix(line, "```") {
				if fenced {
					append(&blocks, Block{first_line = start, lines = slice.clone(run[:], allocator)})
					clear(&run)
				}
				fenced = strings.trim_space(line) == "```odin"
				start = i + 2
				continue
			}
			if fenced {
				append(&run, line)
			}
		}
		return blocks[:]
	}

	run := make([dynamic]string, context.temp_allocator)
	start := 0
	for line, i in lines {
		stripped := strings.trim_left_space(line)
		if strings.has_prefix(stripped, "//\t") {
			if len(run) == 0 {
				start = i + 1
			}
			append(&run, stripped[2:])
			continue
		}
		if len(run) > 0 {
			append(&blocks, Block{first_line = start, lines = slice.clone(run[:], allocator)})
			clear(&run)
		}
	}
	if len(run) > 0 {
		append(&blocks, Block{first_line = start, lines = slice.clone(run[:], allocator)})
	}
	return blocks[:]
}

// The wrapper that turns a listing into something the parser will accept.
//
// `parser.parse_file` wants a whole file - a `package` clause and then declarations - and a listing is
// neither. Wrapping it in a throwaway package and procedure makes the statements parse; the cost is
// that every node's `pos.line` is now offset by however many lines the wrapper added, which is why the
// prefixes are counted rather than eyeballed and `Block_Checker.line_offset` carries the number back
// to the finding.
//
// The wrapped text only has to *parse*. It never type-checks and never compiles, so an undeclared
// `root`, a call to something the fragment never imported, and an `or_return` in a procedure with no
// results are all fine.
@(private = "file")
FRAGMENT_PREFIX :: "package fragment\n_ :: proc() {\n"
@(private = "file")
FRAGMENT_PREFIX_LINES :: 2

// The fallback wrapper, for listings that are declarations rather than statements.
@(private = "file")
DECL_PREFIX :: "package fragment\n"
@(private = "file")
DECL_PREFIX_LINES :: 1

// Strip the wrappers a listing puts around the call it is actually making. `x := f() or_return` binds
// from `f`, not from an `Or_Return_Expr`, and the same goes for `or_else`, `or_break`/`or_continue`
// and a redundant paren - all of which appear in these listings, because they are what the library's
// own idiom looks like.
@(private = "file")
unwrap :: proc(e: ^ast.Expr) -> ^ast.Expr {
	e := e
	for e != nil {
		#partial switch inner in e.derived_expr {
		case ^ast.Or_Return_Expr:
			e = inner.expr
		case ^ast.Or_Branch_Expr:
			e = inner.expr
		case ^ast.Or_Else_Expr:
			e = inner.x
		case ^ast.Paren_Expr:
			e = inner.expr
		case:
			return e
		}
	}
	return e
}

// `sciter_app.foo` and `foo` both name `foo`; anything else names nothing this package knows.
//
// The listings are written from a caller's point of view, so most are qualified - but the ones inside
// `sciter_app/*.odin` doc comments are not, because there the package is implicit. Both spellings have
// to resolve to the same name. A selector with any *other* left-hand side (`strings.builder_make`,
// `fmt.sbprintf`) is somebody else's procedure and is deliberately dropped.
@(private = "file")
called_name :: proc(src: string, call: ^ast.Call_Expr) -> string {
	#partial switch callee in call.expr.derived_expr {
	case ^ast.Ident:
		return callee.name
	case ^ast.Selector_Expr:
		if callee.field == nil {
			return ""
		}
		if pkg, ok := callee.expr.derived_expr.(^ast.Ident); ok && pkg.name != "sciter_app" {
			return ""
		}
		return callee.field.name
	}
	return ""
}

@(private = "file")
Block_Checker :: struct {
	visitor:     ast.Visitor,
	idx:         ^Index,
	src:         string,
	first_line:  int,
	line_offset: int, // lines the wrapper added, so a node maps back to the source file
	bound:       ^map[string]string, // variable -> owned type
	findings:    ^[dynamic]Finding,
}

// Walk a parsed fragment: record what each name was bound from, then judge every call's positional
// arguments against the parameter types the package declares.
//
// `ast.walk` is depth-first in source order, which is what makes one pass enough - a binding is always
// visited before the call that uses it, because it is written above it.
//
// **Two node types for one idea.** Inside a procedure body, `x := f()` is an `ast.Value_Decl` (the
// same node as a top-level declaration, with `is_mutable` set) while `x = f()` is an
// `ast.Assign_Stmt`. They keep their operands under different field names - `names`/`values` against
// `lhs`/`rhs` - so `bind` takes the two slices and both arms call it. A listing uses both spellings,
// which is why neither can be skipped.
@(private = "file")
visit_fragment :: proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
	if n == nil {
		return v
	}
	self := (^Block_Checker)(v.data)

	bind :: proc(self: ^Block_Checker, lhs: []^ast.Expr, rhs: []^ast.Expr) {
		if len(lhs) == 0 || len(rhs) != 1 {
			return
		}
		call, is_call := unwrap(rhs[0]).derived_expr.(^ast.Call_Expr)
		if !is_call {
			return
		}
		producer, is_producer := producer_type(self.idx, called_name(self.src, call))
		if !is_producer {
			return
		}
		target, is_ident := lhs[0].derived_expr.(^ast.Ident)
		if !is_ident || target.name == "_" {
			return
		}
		self.bound[target.name] = producer
	}

	#partial switch node in n.derived {
	case ^ast.Assign_Stmt:
		bind(self, node.lhs, node.rhs)
	case ^ast.Value_Decl:
		bind(self, node.names, node.values)
	case ^ast.Call_Expr:
		name := called_name(self.src, node)
		// `borrow_element` and friends are the fix, not the offence.
		if name == "" || strings.has_prefix(name, "borrow_") {
			break
		}
		i, known := self.idx.by_name[name]
		if !known {
			break // not a procedure of this package
		}
		// `Call_Expr.args` is positional, and `param_types` is one entry per declared parameter name,
		// so the two line up by index. Named arguments would arrive as `ast.Field_Value` and are simply
		// not bound below, which is correct - a named argument is not in a position.
		want := param_types(self.idx.procs[i], context.temp_allocator)
		for arg, pos in node.args {
			if pos >= len(want) {
				break // variadic, or a listing calling something with more arguments than it takes
			}
			ident := unwrap(arg).derived_expr.(^ast.Ident) or_continue
			owner, is_bound := self.bound[ident.name]
			if !is_bound {
				continue
			}
			for pair in OWNED_TYPES {
				if pair.owned != owner || pair.borrowed != strings.trim_space(want[pos]) {
					continue
				}
				append(
					self.findings,
					Finding {
						line = self.first_line + node.pos.line - self.line_offset - 1,
						why = fmt.aprintf(
							"`%s` is an %s and %s takes %s - wrap it in %s",
							ident.name,
							pair.owned,
							name,
							pair.borrowed,
							pair.cast_to,
						),
					},
				)
			}
		}
	}
	return v
}

// The `Owned_*` a procedure hands back, if it hands one back.
@(private = "file")
producer_type :: proc(idx: ^Index, name: string) -> (string, bool) {
	i, known := idx.by_name[name]
	if !known {
		return "", false
	}
	for t in result_types(idx.procs[i], context.temp_allocator) {
		for pair in OWNED_TYPES {
			if contains_word(t, pair.owned) {
				return pair.owned, true
			}
		}
	}
	return "", false
}

@(private = "file")
check_block :: proc(idx: ^Index, block: Block, allocator := context.allocator) -> (findings: []Finding, parsed: bool) {
	// A listing elides the parts that are not the point with `...`, on a line of its own or inside an
	// otherwise empty block. It is prose, not Odin, and it was the single biggest reason a listing
	// would not parse. Blanked rather than deleted, so line numbers still line up with the file the
	// listing came from.
	// Both spellings: the `//` doc comments write it `...` and the markdown guides write it `…`.
	lines := slice.clone(block.lines, context.temp_allocator)
	for &l in lines {
		trimmed := strings.trim_space(l)
		if trimmed == "..." || trimmed == "…" {
			l = ""
			continue
		}
		l, _ = strings.replace_all(l, "{ ... }", "{}", context.temp_allocator)
		l, _ = strings.replace_all(l, "{ … }", "{}", context.temp_allocator)
	}
	body := strings.join(lines, "\n", context.temp_allocator)

	// Three shapes, because the listings are three shapes. Most are statements and go inside a
	// procedure; some are declarations - a handler struct, an `Event_Handler` literal, a whole
	// `on_event` procedure - and only parse at file scope; a few are entire files and bring their own
	// `package` line. Try them in that order rather than guessing from the text which kind a listing
	// is.
	src: string
	line_offset: int
	file: ^ast.File
	ok: bool

	if strings.has_prefix(strings.trim_left_space(body), "package ") {
		src, line_offset = body, 0
		file, ok = parse_source("<listing>", src)
	}
	if !ok {
		src = strings.concatenate({FRAGMENT_PREFIX, body, "\n}\n"}, context.temp_allocator)
		line_offset = FRAGMENT_PREFIX_LINES
		file, ok = parse_source("<listing>", src)
	}
	if !ok {
		src = strings.concatenate({DECL_PREFIX, body, "\n"}, context.temp_allocator)
		line_offset = DECL_PREFIX_LINES
		file, ok = parse_source("<listing>", src)
	}
	if !ok {
		return nil, false
	}

	out := make([dynamic]Finding, allocator)
	bound := make(map[string]string, context.temp_allocator)
	c := Block_Checker {
		idx         = idx,
		src         = src,
		first_line  = block.first_line,
		line_offset = line_offset,
		bound       = &bound,
		findings    = &out,
	}
	c.visitor.data = &c
	c.visitor.visit = visit_fragment
	ast.walk(&c.visitor, &file.node)
	return out[:], true
}

// The listing that shipped the defect this check exists for. Running it every time is what keeps a
// refactor from turning the checker into something that reports nothing and passes.
SELF_TEST := [?]string {
	"item := sciter_app.make_element(\"li\", \"third\") or_return",
	"defer sciter_app.unuse_element(item)",
	"sciter_app.insert_element(item, list) or_return",
}

@(private = "file")
targets :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)

	odin, _ := filepath.glob("sciter_app/*.odin", context.temp_allocator)
	slice.sort(odin)
	append(&out, ..odin)

	docs := make([dynamic]string, context.temp_allocator)
	collect_markdown("docs", &docs)
	slice.sort(docs[:])
	append(&out, ..docs[:])

	append(&out, "README.md")
	return out[:]
}

@(private = "file")
collect_markdown :: proc(dir: string, out: ^[dynamic]string) {
	f, err := os.open(dir)
	if err != nil {
		return
	}
	defer os.close(f)

	entries, read_err := os.read_directory(f, -1, context.temp_allocator)
	if read_err != nil {
		return
	}
	for entry in entries {
		joined, _ := filepath.join({dir, entry.name}, context.temp_allocator)
		path := slashed(joined, context.temp_allocator)
		if entry.type == .Directory {
			collect_markdown(path, out)
		} else if strings.has_suffix(entry.name, ".md") {
			append(out, path)
		}
	}
}

// `--show-skipped` prints the listings neither wrapper could parse. The skipped count is in the ok
// line so a coverage regression is visible; this is how you find out *what* stopped being covered.
check_doc_ownership :: proc(self_test: bool, show_skipped := false) -> int {
	idx := sciter_app_index()

	producers := 0
	for pi in idx.procs {
		if _, is := producer_type(&idx, pi.name); is {
			producers += 1
		}
	}
	if producers == 0 {
		fmt.eprintln("no Owned_* producers found - has the package moved?")
		return 1
	}

	if self_test {
		found, parsed := check_block(&idx, Block{first_line = 1, lines = SELF_TEST[:]})
		if !parsed {
			fmt.eprintln("self-test FAILED: the listing known to be wrong no longer parses")
			return 1
		}
		if len(found) != 1 {
			fmt.eprintfln("self-test FAILED: expected 1 problem in a listing known to be wrong, got %d", len(found))
			return 1
		}
		fmt.printfln("self-test ok: %s", found[0].why)
		return 0
	}

	bad, blocks, skipped := 0, 0, 0
	for path in targets(context.temp_allocator) {
		src, read_ok := read_file(path)
		if !read_ok {
			continue
		}
		for block in code_blocks(path, src) {
			blocks += 1
			findings, parsed := check_block(&idx, block)
			if !parsed {
				skipped += 1
				if show_skipped {
					fmt.printfln("--- skipped %s:%d", path, block.first_line)
					for l in block.lines {
						fmt.printfln("    %s", l)
					}
				}
				continue
			}
			for f in findings {
				bad += 1
				fmt.printfln("%s:%d: %s", path, f.line, f.why)
			}
		}
	}

	if bad > 0 {
		fmt.printfln("\n%d listing(s) would not compile. Code in a comment is still code someone pastes.", bad)
		return 1
	}
	fmt.printfln(
		"ok: %d code listings in doc comments and guides (%d not parseable as statements, skipped), " +
		"%d Owned_* producers, none handed to a borrowed parameter",
		blocks,
		skipped,
		producers,
	)
	return 0
}
