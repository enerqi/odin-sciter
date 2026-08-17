// C-API coverage: which SCFN slots the headers declare, and which of them `package sciter_app`
// reaches.
//
// `just api-map-verify` answers the other half of the same question - that the slots the bindings
// expect resolve to the right symbols in the engine that shipped. That catches a reordered or removed
// slot. It cannot catch an *added* one: a new SDK with six more slots regenerates into `sciter.odin`
// as six fields nothing wraps, and nothing says so. This is that check, and the reason it belongs
// next to the other one in CI and in docs/UPGRADING.md.
//
// Two counting rules, both of which a naive text search gets wrong:
//
//   - **comments and `#if 0` are stripped first.** `imageGetPixels` (sciter-x-graphics.h) is inside a
//     `//` block and `Request` (sciter-x-request.h) is inside `#if 0`; both match a bare SCFN search
//     and neither exists. Counting them as gaps produces two findings that can never be closed.
//   - **usage is a mention, not a call.** The wrappers frequently store or forward a slot rather than
//     calling it on the spot, so requiring an open paren undercounts.
//
//	parity            print the tables
//	parity --check    print them, then exit 1 if the unwrapped set differs from the baseline
//
// The baseline is docs/parity-baseline.txt: the sorted list of declared-but-unwrapped slots, each one
// a decision somebody made. A diff against it is the upgrade asking a question, at the moment the
// person doing the upgrade is the right one to answer it.
//
// **The two halves are measured differently, on purpose.** The header side is C, and neither
// `core:odin/parser` nor anything else here can parse it - so it stays a text scan, with the comment
// and `#if 0` stripping written out. The `sciter_app` side is Odin, so it is the parsed package: a
// slot counts as reached when some file writes `.SciterFoo` as an actual selector, which a mention in
// a doc comment is not. That is stricter than the text search it replaces, and the baseline is
// unchanged by it - checked.
package checks

import "core:fmt"
import "core:slice"
import "core:strings"

INCLUDE_DIR :: "external/sciter/include"
BASELINE :: "docs/parity-baseline.txt"

@(private = "file")
Table :: struct {
	title:  string,
	header: string,
}

TABLES := [?]Table {
	{"main table", "sciter-x-api.h"},
	{"graphics sub-table", "sciter-x-graphics.h"},
	{"request sub-table", "sciter-x-request.h"},
}

// Remove `#if 0 ... #endif` blocks, then `/* */` and `//` comments - in that order.
@(private = "file")
strip_dead_code :: proc(text: string, allocator := context.allocator) -> string {
	kept := make([dynamic]string, context.temp_allocator)
	skip := false
	for line in strings.split_lines(text, context.temp_allocator) {
		trimmed := strings.trim_left_space(line)
		if strings.has_prefix(trimmed, "#if 0") {
			skip = true
			continue
		}
		if skip {
			if strings.has_prefix(trimmed, "#endif") {
				skip = false
			}
			continue
		}
		append(&kept, line)
	}

	body := strings.join(kept[:], "\n", context.temp_allocator)

	// One pass, because a `//` inside a `/* */` is not a line comment and a `/*` inside a `//` line is
	// not a block. Running two independent replacements over the same text - which is what a pair of
	// regex substitutions does - gets both of those wrong.
	out := strings.builder_make(allocator)
	i := 0
	for i < len(body) {
		if strings.has_prefix(body[i:], "/*") {
			end := strings.index(body[i + 2:], "*/")
			i = end < 0 ? len(body) : i + 2 + end + 2
			continue
		}
		if strings.has_prefix(body[i:], "//") {
			end := strings.index_byte(body[i:], '\n')
			i = end < 0 ? len(body) : i + end
			continue
		}
		strings.write_byte(&out, body[i])
		i += 1
	}
	return strings.to_string(out)
}

// The names inside `SCFN(...)`, sorted and deduplicated.
@(private = "file")
slots :: proc(header: string, allocator := context.allocator) -> ([]string, bool) {
	path := strings.concatenate({INCLUDE_DIR, "/", header}, context.temp_allocator)
	src, ok := read_file(path, context.temp_allocator)
	if !ok {
		fmt.eprintfln("cannot read %s", path)
		return nil, false
	}

	live := strip_dead_code(src, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	out := make([dynamic]string, allocator)

	rest := live
	for {
		at := strings.index(rest, "SCFN(")
		if at < 0 {
			break
		}
		rest = rest[at + len("SCFN("):]
		name := strings.trim_left_space(rest)
		n := 0
		for n < len(name) && is_word_byte(name[n]) {
			n += 1
		}
		if n > 0 && !seen[name[:n]] {
			seen[name[:n]] = true
			append(&out, name[:n])
		}
	}
	slice.sort(out[:])
	return out[:], true
}

@(private = "file")
report :: proc(table: Table, reached: ^map[string]bool, unwrapped: ^[dynamic]string) -> bool {
	all, ok := slots(table.header, context.temp_allocator)
	if !ok {
		return false
	}

	unused := make([dynamic]string, context.temp_allocator)
	for name in all {
		if !reached[name] {
			append(&unused, name)
		}
	}

	fmt.printfln("%s (%s -> sciter_app)", table.title, table.header)
	fmt.printfln("  declared (live): %d", len(all))
	fmt.printfln("  reached:         %d", len(all) - len(unused))
	fmt.printfln("  not reached:     %d", len(unused))
	for name in unused {
		fmt.printfln("    %s", name)
	}
	fmt.println()

	for name in unused {
		append(unwrapped, fmt.aprintf("%s %s", table.header, name))
	}
	return true
}

run_parity :: proc(check: bool) -> int {
	idx := sciter_app_index()

	// Every `.field` the package writes. A slot is reached when one of them is its name.
	reached := make(map[string]bool)
	for sf in idx.files {
		selector_fields(&sf.file.node, &reached)
	}

	unwrapped := make([dynamic]string)

	fmt.println("C-API coverage, measured from the vendored headers")
	fmt.println()
	for table in TABLES {
		if !report(table, &reached, &unwrapped) {
			return 1
		}
	}

	if !check {
		return 0
	}

	slice.sort(unwrapped[:])

	baseline_src, ok := read_file(BASELINE)
	if !ok {
		fmt.eprintfln("cannot read %s", BASELINE)
		return 1
	}
	want := make([dynamic]string)
	for line in strings.split_lines(baseline_src, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed != "" {
			append(&want, trimmed)
		}
	}

	// A sorted set difference rather than a line diff: both sides are sorted lists of one entry each,
	// so `+`/`-` is the whole of the information a unified diff would carry here, and it is exactly
	// what the two sentences below explain.
	added := make([dynamic]string)
	removed := make([dynamic]string)
	in_baseline := set_of(want[:], context.temp_allocator)
	in_measured := set_of(unwrapped[:], context.temp_allocator)
	for line in unwrapped {
		if !in_baseline[line] {
			append(&added, line)
		}
	}
	for line in want {
		if !in_measured[line] {
			append(&removed, line)
		}
	}

	if len(added) == 0 && len(removed) == 0 {
		fmt.printfln("unwrapped set matches %s", BASELINE)
		return 0
	}

	fmt.println("the set of unwrapped slots has changed:")
	for line in removed {
		fmt.printfln("  -%s", line)
	}
	for line in added {
		fmt.printfln("  +%s", line)
	}
	fmt.println()
	fmt.printfln("A '+' line is a slot nothing wraps - decide about it and add it to %s with a reason", BASELINE)
	fmt.println("in docs/SDK-PARITY.md, or wrap it. A '-' line means one got wrapped: drop it from the baseline.")
	return 1
}
