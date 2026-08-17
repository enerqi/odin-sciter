// Checks the ownership rule in docs/rules.md section 4:
//
//	If it takes an allocator, the result is yours to free. If it does not, it is borrowed.
//
// Every exported procedure in `package sciter_app` that returns a string or a slice must either take
// an `allocator` parameter (so the caller owns the result) or be listed in BORROWED below with the
// lifetime its doc comment names. A new procedure that returns allocated memory without taking an
// allocator, or a borrowing one that nobody has written down, fails the build.
//
// This exists because the rule is the only ownership question in the package with a mechanical answer
// - `Value` needs prose - and a rule nothing checks drifts.
//
// **What the AST changed.** The Python original hand-rolled `split_signature`, a paren matcher, to
// find where the parameter list ended and the results began, because "most of the signatures in this
// package" wrap over several lines and a regex stops at the first newline. It then searched the whole
// results *text* for a memory-returning type, with lookarounds to stop `string` matching inside
// `cstring`. Here the parser has already separated params from results and split the results into
// fields, so the test is exact-match on each result type's spelling - `cstring` is simply not
// `string`, and no lookaround is needed to say so.
package checks

import "core:fmt"
import "core:slice"
import "core:strings"

// Procedures that return engine-owned memory. The value is the lifetime, and it must match what the
// doc comment says; adding a name here is a deliberate act, which is the point.
BORROWED := [?]Exemption {
	{"tag", "the element's lifetime"},
	{"request_method", "the request's lifetime"},
	{"value_to_bytes", "until the Value changes or is cleared"},
	{"archive_item", "until close_archive"},
}

// Types whose return means "memory came back". `[]u16` is the wrapper's own UTF-16 scratch, which
// takes an allocator like everything else.
RETURNS_MEMORY := [?]string{"string", "[]u8", "[]u16", "[]string", "[]Element", "[]Name_Value", "[]Attribute"}

@(private = "file")
returns_memory :: proc(pi: Proc_Info) -> bool {
	for t in result_types(pi, context.temp_allocator) {
		trimmed := strings.trim_space(t)
		if slice.contains(RETURNS_MEMORY[:], trimmed) {
			return true
		}
	}
	return false
}

@(private = "file")
takes_allocator :: proc(pi: Proc_Info) -> bool {
	for n in param_names(pi, context.temp_allocator) {
		if n == "allocator" {
			return true
		}
	}
	return false
}

check_ownership :: proc() -> int {
	idx := sciter_app_index()

	problems := make([dynamic]string)
	seen_borrowed := make(map[string]bool)
	checked := 0

	for pi in idx.procs {
		// The rule is about the package's API surface. A file-private helper may hand back temp memory
		// to its own file - `behavior_name` in host.odin does - and no caller outside can misread it.
		if pi.private {
			continue
		}
		c := pi.name[0]
		if !(c == '_' || (c >= 'a' && c <= 'z')) {
			continue
		}
		if !returns_memory(pi) {
			continue
		}
		checked += 1

		allocates := takes_allocator(pi)
		listed := exempt(BORROWED[:], pi.name)

		if allocates && listed {
			append(
				&problems,
				fmt.aprintf(
					"%s:%d: %s takes an allocator but is listed as borrowed - one of the two is wrong",
					pi.file,
					pi.line,
					pi.name,
				),
			)
		} else if !allocates && !listed {
			append(
				&problems,
				fmt.aprintf(
					"%s:%d: %s returns memory but takes no allocator. Either give it one (the caller " +
					"owns the result) or add it to BORROWED in this file with the lifetime its doc " +
					"comment names.",
					pi.file,
					pi.line,
					pi.name,
				),
			)
		}
		if listed {
			seen_borrowed[pi.name] = true
		}
	}

	for e in BORROWED {
		if !(e.name in seen_borrowed) {
			append(&problems, fmt.aprintf("BORROWED lists '%s', which no longer returns memory - drop it", e.name))
		}
	}

	if len(problems) > 0 {
		fmt.eprintln("ownership rule violated (docs/rules.md section 4):\n")
		for p in problems {
			fmt.eprintfln("  %s", p)
		}
		return 1
	}

	fmt.printfln(
		"ok: %d procedures return memory; %d take an allocator, %d are documented borrows",
		checked,
		checked - len(seen_borrowed),
		len(seen_borrowed),
	)
	return 0
}
