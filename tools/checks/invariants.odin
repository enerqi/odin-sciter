// Checks three invariants that hold today and that nothing was keeping true.
//
//	A. a procedure that hands back a Value records it in the ledger
//	B. a procedure that hands back an owned engine handle records it too
//	C. every `proc "system"` the engine calls back into restores a context
//
// None of the three is a rule a reader can see being broken. A missing `tracked()` makes
// `just leak-check` report clean while leaking - and `tracking.odin` says why that direction is the
// dangerous one: an under-flow is catchable the instant it happens, a leak is only ever a question
// you can ask at the end. A `proc "system"` that allocates without restoring a context is, per the
// angle-9 sweep, "the failure mode most likely to produce unexplainable corruption".
//
// All three were verified by hand in the 2026-08-13 review and were still clean when this was
// written. That is the argument for the check rather than against it: `docs/review/10-threading.md`
// is about an invariant that was hand-verified, drifted, and then hid the drift for a day on the one
// platform nobody can watch.
//
// Delegation is followed. A procedure counts as inside the enforcement if it records the resource
// itself or calls something that does, because otherwise every `scoped_` twin and every wrapper reads
// as a hole and buries the real ones - 40 false positives against 8 real questions, measured.
//
// **What the AST changed.** Three approximations, and the first was the load-bearing one. Finding a
// procedure's body meant scanning forward for a line ending in `{` and giving up at a blank line or
// the next column-0 declaration - without that second half the scan ran on into the *next*
// procedure's brace and every callback *type* read as a definition. The parser draws that boundary
// itself. Selecting on the return type meant `->\s*\(?[^)]*\bValue\b`, a regex that cannot cross a
// `)` and therefore has to be reasoned about against `-> (v: Value, ok: bool)` and against a callback
// parameter that has its own `->`; here the results are a field list and each one's type is read
// directly. And the call graph came from `\b([a-z_][a-z_0-9]*)\s*\(`, which also matches `if (`, a
// type conversion, and any of the three inside a comment or a string.
package checks

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

VALUE_EXEMPT := [?]Exemption {
	{"value_from_bool", "an inline payload - the Value owns nothing and clearing it is a no-op"},
	{"value_from_int", "inline payload"},
	{"value_from_i64", "inline payload"},
	{"value_from_f64", "inline payload"},
	{"value_from_asset", "a bare ValueInt64DataSet - the engine does not add_ref, see `.ASSET` in tracking.odin"},
	{"scope_add", "hands back a Value that its producer already recorded"},
}

HANDLE_EXEMPT := [?]Exemption {
	{"value_to_graphics", "unwraps the handle the Value already holds - borrowed, the Value still owns it"},
	{"value_to_image", "borrowed from the Value, as above"},
	{"value_to_path", "borrowed from the Value, as above"},
	{"value_to_text", "borrowed from the Value, as above"},
}

CONTEXT_EXEMPT := [?]Exemption {
	{"asset_add_ref", "allocates nothing"},
	{"asset_release", "allocates nothing"},
	{"asset_get_interface", "allocates nothing"},
	{"asset_get_passport", "only dereferences"},
}

// The handle types whose return means the caller now owns something the engine counted.
OWNED_HANDLES := [?]string {
	"Owned_Element",
	"Owned_Node",
	"Owned_Request",
	"Image",
	"Path",
	"Text",
	"Archive",
	"Graphics",
}

// The three rules share a runner, so each is a selector, a test and a table.
//
// `selects` and `satisfied` are plain procedure-pointer fields - Odin has no closures, so a rule
// cannot capture anything, and everything either of them needs arrives as an argument. `satisfied`
// takes the index because two of the three have to walk the call graph.
@(private = "file")
Rule :: struct {
	label:     string,
	remedy:    string,
	selects:   proc(pi: Proc_Info) -> bool,
	satisfied: proc(idx: ^Index, pi: Proc_Info) -> bool,
	exempt:    []Exemption,
}

// --- rule A: the Value ledger ----------------------------------------------------------------------

@(private = "file")
returns_value :: proc(pi: Proc_Info) -> bool {
	if pi.type == nil {
		return false
	}
	found := false
	for t in result_types(pi, context.temp_allocator) {
		// A `^Value` result is a pointer into something that already owns the reference - the ledger
		// is about handing back a Value, not a view of one.
		if strings.contains(t, "^Value") {
			return false
		}
		if contains_word(t, "Value") {
			found = true
		}
	}
	return found
}

// --- rule B: the handle ledger ---------------------------------------------------------------------

@(private = "file")
returns_handle :: proc(pi: Proc_Info) -> bool {
	if pi.type == nil {
		return false
	}
	for t in result_types(pi, context.temp_allocator) {
		for h in OWNED_HANDLES {
			if contains_word(t, h) {
				return true
			}
		}
	}
	return false
}

// --- rule C: the callback context --------------------------------------------------------------------

@(private = "file")
is_system_proc :: proc(pi: Proc_Info) -> bool {
	return calling_convention(pi) == "system"
}

@(private = "file")
Context_Finder :: struct {
	visitor: ast.Visitor,
	found:   ^bool,
}

// `context = ...` anywhere in the body, at any nesting. Unlike `^\s*context = ` it does not care how
// the line was indented or how many spaces sit around the `=`, and it cannot match the same text
// inside a comment.
//
// `context` is a keyword, not an identifier - the parser gives it an `ast.Implicit` node carrying the
// `.Context` token, not an `ast.Ident`. Matching `Ident{name = "context"}` finds nothing at all, which
// is not a subtle failure: it reported every one of the nineteen `proc "system"` in the package.
@(private = "file")
restores_context :: proc(idx: ^Index, pi: Proc_Info) -> bool {
	if pi.lit == nil || pi.lit.body == nil {
		return false
	}
	found := false
	f := Context_Finder {
		found = &found,
	}
	f.visitor.data = &f
	f.visitor.visit = proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor {
		if n == nil {
			return v
		}
		self := (^Context_Finder)(v.data)
		// `context = x` is an `Assign_Stmt` whose left side is *not* an `Ident`. `context` is a keyword,
		// so the parser emits an `ast.Implicit` node carrying the `.Context` token kind - the same node
		// it uses for other keyword-shaped expressions. Matching `Ident{name = "context"}` here finds
		// nothing at all, and the symptom is not subtle: it reported all nineteen `proc "system"` in the
		// package as unguarded.
		if assign, ok := n.derived.(^ast.Assign_Stmt); ok && len(assign.lhs) > 0 {
			if imp, is_implicit := assign.lhs[0].derived_expr.(^ast.Implicit); is_implicit {
				if imp.tok.kind == .Context {
					self.found^ = true
				}
			}
		}
		return v
	}
	ast.walk(&f.visitor, &pi.lit.body.stmt_base)
	return found
}

@(private = "file")
reaches_tracked :: proc(idx: ^Index, pi: Proc_Info) -> bool {
	targets := set_of({"tracked", "track_acquire_counted"}, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	return reaches(idx, pi.name, targets, &seen)
}

@(private = "file")
reaches_acquire :: proc(idx: ^Index, pi: Proc_Info) -> bool {
	targets := set_of({"track_acquire"}, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	return reaches(idx, pi.name, targets, &seen)
}

// --- the runner ------------------------------------------------------------------------------------

@(private = "file")
Count :: struct {
	label:   string,
	checked: int,
	inside:  int,
	exempt:  int,
}

@(private = "file")
run_rule :: proc(idx: ^Index, rule: Rule, problems: ^[dynamic]string) -> Count {
	used := make(map[string]bool, context.temp_allocator)
	checked, inside := 0, 0

	for pi in idx.procs {
		// A procedure group has no signature and no body; a foreign declaration has no body. Neither
		// can satisfy or violate any of these, and neither should be counted as checked.
		if pi.lit == nil || pi.lit.body == nil {
			continue
		}
		if !rule.selects(pi) {
			continue
		}
		checked += 1

		is_exempt := exempt(rule.exempt, pi.name)
		if rule.satisfied(idx, pi) {
			inside += 1
			if is_exempt {
				append(
					problems,
					fmt.aprintf(
						"%s:%d: %s is listed as exempt from %s but satisfies it now - drop it from " +
						"the list in invariants.odin",
						pi.file,
						pi.line,
						pi.name,
						rule.label,
					),
				)
				used[pi.name] = true
			}
			continue
		}
		if is_exempt {
			used[pi.name] = true
			continue
		}
		append(problems, fmt.aprintf("%s:%d: %s %s", pi.file, pi.line, pi.name, rule.remedy))
	}

	gone := make([dynamic]string, context.temp_allocator)
	for e in rule.exempt {
		if !(e.name in used) {
			append(&gone, e.name)
		}
	}
	slice.sort(gone[:])
	for name in gone {
		append(
			problems,
			fmt.aprintf("'%s' is listed as exempt from %s but no longer matches - drop it", name, rule.label),
		)
	}

	return Count{label = rule.label, checked = checked, inside = inside, exempt = len(used)}
}

check_invariants :: proc() -> int {
	idx := sciter_app_index()
	problems := make([dynamic]string)

	rules := [?]Rule {
		{
			label = "A (Value ledger)",
			remedy = "hands back a Value and never reaches `tracked()`. Either return `tracked(v)` so " +
			"the reference is counted, or add it to VALUE_EXEMPT in invariants.odin with the reason it " +
			"owns nothing.",
			selects = returns_value,
			satisfied = reaches_tracked,
			exempt = VALUE_EXEMPT[:],
		},
		{
			label = "B (handle ledger)",
			remedy = "hands back an engine handle and never reaches `track_acquire()`. Either record " +
			"it, or add it to HANDLE_EXEMPT in invariants.odin with the reason the caller does not own it.",
			selects = returns_handle,
			satisfied = reaches_acquire,
			exempt = HANDLE_EXEMPT[:],
		},
		{
			label = "C (callback context)",
			remedy = "is a `proc \"system\"` with no `context = ` in it. The engine calls it on a thread " +
			"with no Odin context, so anything that allocates - `fmt`, `make`, a temp-allocator string - " +
			"reads whatever was there. Restore one, or add it to CONTEXT_EXEMPT with the reason it needs none.",
			selects = is_system_proc,
			satisfied = restores_context,
			exempt = CONTEXT_EXEMPT[:],
		},
	}

	counts := make([dynamic]Count)
	for rule in rules {
		append(&counts, run_rule(&idx, rule, &problems))
	}

	// The counts print either way. On success they are the reassurance; on failure they are the scale -
	// "4 of 58 procedures" is a different message from "4 findings", and the reader needs to know which
	// of the three rules is in trouble before reading twenty lines of remedy text.
	failed := len(problems) > 0
	for c in counts {
		fmt.printfln(
			"%s%s - %d procedures, %d satisfy it, %d documented exemptions",
			failed ? "" : "ok: ",
			c.label,
			c.checked,
			c.inside,
			c.exempt,
		)
	}

	if failed {
		fmt.eprintln("\ninvariant unenforced:\n")
		for p in problems {
			fmt.eprintfln("  %s", p)
		}
		return 1
	}
	return 0
}
