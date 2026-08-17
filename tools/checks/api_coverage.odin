// Every exported procedure of `sciter_app` has to appear in docs/api.md, which is the page that
// promises to say what exists.
//
// `stats` already counts the exported procedures and asserts that a test reaches every one of them.
// Nothing asserted that a *reader* could find them, and the gap that opened was not a scattering of
// odd names: api.md is organised one section per source file, and three files had no section at all -
// `scoped.odin` (26 procedures), `value_scope.odin` (4) and `tracking.odin` (4). That is the whole
// leak-prevention surface and the whole debug ledger, which is to say the two APIs `docs/rules.md`
// sends a newcomer to look up. 340 of 402 procedures were mentioned.
//
// Several of the missing were "documented" only by a wildcard - `retain_*` / `release_*`, "the four
// `set_*_gradient_*`". That reads well and is not checkable, and a reader searching for `retain_text`
// does not find it, so this check wants the literal name and the page now spells the families out.
//
// **Only this direction is checked.** A name in api.md that no longer exists would be the other kind
// of rot, and it is not checkable the same way: api.md writes procedure names bare, in the same
// backticks it uses for types, struct fields, enum members and C-API names, so "looks like a
// procedure" has no honest definition here. `just check` catches the same rot in the compiled
// snippets, which is where it matters.
package checks

import "core:fmt"
import "core:slice"

API_MD :: "docs/api.md"

// The package's API surface: a top-level `name :: proc` that is not `@(private)`.
//
// Lowercase-initial, matching the convention the package follows without exception - and matching the
// Python original, whose regex was `^[a-z_][a-zA-Z0-9_]* :: proc`. An exported type is Ada_Case here,
// so the case test is also what keeps `Asset_Call`-shaped callback *types* out; the AST keeps them out
// anyway, since a type declaration is not a `Proc_Lit`.
exported_procs :: proc(idx: ^Index, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for pi in idx.procs {
		if pi.private {
			continue
		}
		c := pi.name[0]
		if !(c == '_' || (c >= 'a' && c <= 'z')) {
			continue
		}
		append(&out, pi.name)
	}
	slice.sort(out[:])
	return out[:]
}

// `--list` prints the measured surface and nothing else. It is what you run when this check and
// `stats` disagree with something, or when comparing the AST's answer against an older text-scanning
// one - which is exactly how the four names the Python version over-counted were found.
check_api_coverage :: proc(list_only := false) -> int {
	idx := sciter_app_index()
	exported := exported_procs(&idx)

	if list_only {
		for name in exported {
			fmt.println(name)
		}
		return 0
	}

	if len(exported) == 0 {
		fmt.eprintln("no exported procedures found - has package sciter_app moved?")
		return 1
	}

	api, ok := read_file(API_MD)
	if !ok {
		fmt.eprintfln("cannot read %s", API_MD)
		return 1
	}

	missing := make([dynamic]string)
	for name in exported {
		if !contains_word(api, name) {
			append(&missing, name)
		}
	}

	if len(missing) > 0 {
		fmt.printfln("%s does not mention %d of %d exported procedures:\n", API_MD, len(missing), len(exported))
		for name in missing {
			fmt.printfln("  %s", name)
		}
		fmt.println(
			"\napi.md is the page that answers \"what exists\". Add them to the section for the file they\n" +
			"live in - and spell the name out rather than covering a family with a `*`, which no check\n" +
			"can see and no reader can search for.",
		)
		return 1
	}

	fmt.printfln("ok: %s mentions all %d exported procedures of sciter_app", API_MD, len(exported))
	return 0
}
