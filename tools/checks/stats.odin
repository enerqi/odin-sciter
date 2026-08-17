// The numbers the documentation quotes about itself: how many examples, how many tests, how many of
// the wrapper's exported procedures a test actually reaches, how many documents there are, and how
// many upstream defects are written up.
//
// These were hand-maintained and had drifted - README and PLAN both said 337 tests against an actual
// 364-odd, which is the sort of claim a sceptical reader checks first and the sort that quietly
// undersells the work. Anything a doc asserts about this repository's size should come from here.
//
// The counting rule that matters, and the one this repository has already been bitten by: a wrapper
// is matched as a *mention*, not as a call. The examples frequently store or forward a procedure
// rather than calling it on the spot, and requiring the open paren undercounts.
//
// **Quote these as numerals, not words.** `--check` is a text search over the prose, so "twelve
// guides" is invisible to it and drifted for exactly that reason - it survived three counts changing
// underneath it. A number a doc asserts about this repository is either written as a digit and
// checked here, or it is going to be wrong.
//
//	stats            print the numbers
//	stats --check    also verify the numbers quoted in README.md, docs/README.md and docs/PLAN.md
package checks

import "core:fmt"
import "core:path/filepath"
import "core:slice"
import "core:strings"

UPSTREAM_DEFECTS :: "docs/UPSTREAM-DEFECTS.md"

// The exported procedures no example mentions. Carried out of `measure` so `--uncovered` can name
// them: "402 of 403" is a number to argue with, and the argument needs the name.
@(private = "file")
SHOW_UNCOVERED: struct {
	list: []string,
}

@(private = "file")
Numbers :: struct {
	examples:   int,
	test_files: int,
	tests:      int,
	exported:   int,
	covered:    int,
	docs:       int,
	defects:    int,
}

// Numbered `## N.` headings in the defect register.
@(private = "file")
count_defect_headings :: proc(src: string) -> int {
	n := 0
	for line in strings.split_lines(src, context.temp_allocator) {
		if !strings.has_prefix(line, "## ") {
			continue
		}
		rest := line[3:]
		digits := 0
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
			digits += 1
		}
		if digits > 0 && strings.has_prefix(rest[digits:], ". ") {
			n += 1
		}
	}
	return n
}

@(private = "file")
measure :: proc() -> (num: Numbers, ok: bool) {
	idx := sciter_app_index()
	exported := exported_procs(&idx)

	examples, _ := filepath.glob("examples/*.odin", context.temp_allocator)
	slice.sort(examples)

	// Every `.name` the example suite writes, from every example at once - the question is whether
	// *some* test reaches a wrapper, not which one.
	mentioned := make(map[string]bool, context.temp_allocator)

	tests, test_files := 0, 0
	for path in examples {
		src, read_ok := read_file(path, context.temp_allocator)
		if !read_ok {
			fmt.eprintfln("cannot read %s", path)
			return {}, false
		}
		file, parsed := parse_source(path, src)
		if !parsed {
			fmt.eprintfln("%s did not parse", path)
			return {}, false
		}

		selector_fields(&file.node, &mentioned)

		// A test is `@(test)` on a declaration - not the string `@(test)` anywhere in the file, which
		// over-reported by one: `examples/eval.odin`'s header says "the `@(test)` procs at the bottom
		// exercise the conversions", and prose about tests was being counted as a test. Other
		// attributes stacked alongside are handled because the parser collects them all; the regex
		// this replaces had to spell that case out and would otherwise have dropped them, which is the
		// worse error - a test nothing counts is a test nothing misses.
		in_file := count_attributed_decls(&file.node, "test")
		tests += in_file
		if in_file > 0 {
			test_files += 1
		}
	}

	covered := 0
	uncovered := make([dynamic]string, context.temp_allocator)
	for name in exported {
		if mentioned[name] {
			covered += 1
		} else {
			append(&uncovered, name)
		}
	}
	SHOW_UNCOVERED.list = uncovered[:]

	// Every .md under docs/, excluding the index itself and the review set - the index counts what it
	// indexes, and docs/review/ is a dated audit rather than documentation of the library.
	doc_files, _ := filepath.glob("docs/*.md", context.temp_allocator)
	docs := 0
	for p in doc_files {
		if filepath.base(p) != "README.md" {
			docs += 1
		}
	}

	defect_src, defects_ok := read_file(UPSTREAM_DEFECTS, context.temp_allocator)
	if !defects_ok {
		fmt.eprintfln("cannot read %s", UPSTREAM_DEFECTS)
		return {}, false
	}

	return Numbers {
			examples = len(examples),
			test_files = test_files,
			tests = tests,
			exported = len(exported),
			covered = covered,
			docs = docs,
			defects = count_defect_headings(defect_src),
		},
		true
}

run_stats :: proc(check: bool, show_uncovered := false) -> int {
	num, ok := measure()
	if !ok {
		return 1
	}

	if show_uncovered {
		for name in SHOW_UNCOVERED.list {
			fmt.printfln("no example mentions %s", name)
		}
	}

	fmt.printfln("examples:            %d files, %d with tests", num.examples, num.test_files)
	fmt.printfln("tests:               %d @(test) procs", num.tests)
	fmt.printfln("wrapper procs:       %d exported", num.exported)
	fmt.printfln("reached from a test: %d", num.covered)
	fmt.printfln("docs:                %d besides docs/README.md", num.docs)
	fmt.printfln("upstream defects:    %d written up", num.defects)

	if !check {
		return 0
	}

	fail := false

	// Each check is anchored to a file that actually makes the claim. `README.md` used to carry a
	// status blockquote with the test, example and doc counts in it; when that was removed, the checks
	// for it started failing against prose that no longer existed. The rule that keeps this honest: a
	// check belongs where the sentence is, and a claim that moves takes its check with it. Do not
	// "fix" a failure here by making the pattern optional - a check that passes when the text is
	// absent is the same blind spot as the hand-maintained counts this replaced.
	claim :: proc(fail: ^bool, relpath, what, phrase: string) {
		src, ok := read_file(relpath, context.temp_allocator)
		if !ok || !contains_word(src, phrase) {
			fmt.printfln("%s does not quote the current %s (%s)", relpath, what, phrase)
			fail^ = true
		}
	}

	tmp :: proc(format: string, args: ..any) -> string {
		return fmt.aprintf(format, ..args, allocator = context.temp_allocator)
	}

	claim(&fail, "docs/PLAN.md", "test count", tmp("%d", num.tests))
	claim(&fail, "docs/PLAN.md", "coverage", tmp("%d of its %d", num.covered, num.exported))
	claim(&fail, "docs/PLAN.md", "example count", tmp("%d examples", num.examples))
	claim(&fail, "docs/PLAN.md", "doc count", tmp("%d documents", num.docs))
	claim(&fail, "docs/README.md", "doc count", tmp("%d files besides this index", num.docs))
	claim(&fail, "README.md", "upstream defect count", tmp("%d engine defects", num.defects))

	if fail {
		fmt.println()
		fmt.println("Update the docs, or the code changed the numbers - either way they are meant to agree.")
		return 1
	}
	fmt.println("README.md, docs/README.md and docs/PLAN.md agree with the measurement")
	return 0
}
