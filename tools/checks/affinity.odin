// Checks the thread-affinity rule in docs/rules.md section 1:
//
//	Every call into this library must happen on the thread that called `init`.
//
// The runtime half of that rule is `guard_engine_thread` in `sciter_app/affinity.odin`, and it can
// only check calls that pass through it. `engine()` in `sciter_app.odin` is what makes that "all of
// them": it is the only way the package reaches the engine's function table, and it guards on the way
// in. This check is what keeps that true - a new procedure written with a bare `sciter.api()` would
// compile, work, and be invisible to the guard.
//
// It exists because that is exactly what happened. The guard originally sat in the four
// error-wrapping helpers and the two sub-table accessors, so it saw a call only if that call returned
// a result code: 124 of 199 engine call sites, with `eval`, `call`, every `Value` constructor and the
// whole windowless surface among the 75 it missed. Nothing failed, because nothing was checking. See
// `docs/review/10-threading.md`.
//
// **What the AST changed.** The Python original worked a line at a time: rebuild a line -> enclosing
// procedure map from column-0 regex matches, skip any line that is only a comment, then search the
// line for `\bengine\s*\(`. Three approximations in that, all now gone. A call is a `Call_Expr`, so a
// comment can never be one - including a trailing comment on a line of real code, which the
// comment-only test did not cover and which is where four of the five mentions of `sciter.api()` in
// prose live. Two calls on one line count twice rather than once. And the enclosing procedure comes
// from the declaration's own byte range instead of a scan between column-0 matches.
package checks

import "core:fmt"

// The one place a bare `sciter.api()` is correct. `post_callback` is rule 1's documented exception -
// it is meant to be called from a worker thread, so the guard would trap the use it exists for.
AFFINITY_EXEMPT := [?]Exemption {
	{"post_callback", "rule 1's one exception - safe from any thread, see docs/threading.md"},
}

// Where `engine()` itself lives. It is the wrapper around `sciter.api()`, so it is not a violation of
// the rule it implements.
DEFINITION_FILE :: "sciter_app/sciter_app.odin"
DEFINITION_PROC :: "engine"

check_affinity :: proc() -> int {
	idx := sciter_app_index()

	problems := make([dynamic]string)
	seen_exempt := make(map[string]bool)
	guarded := 0

	for sf in idx.files {
		for site in collect_calls(&sf.file.node, sf.src, context.temp_allocator) {
			if site.callee != "engine" && site.callee != "sciter.api" {
				continue
			}

			owner := enclosing_proc(&idx, sf.path, site.pos.offset)
			name := owner == nil ? "<file scope>" : owner.name
			is_definition := sf.path == DEFINITION_FILE && name == DEFINITION_PROC

			if site.callee == "engine" {
				if !is_definition {
					guarded += 1
				}
				continue
			}

			if is_definition {
				continue
			}
			if exempt(AFFINITY_EXEMPT[:], name) {
				seen_exempt[name] = true
				continue
			}
			append(
				&problems,
				fmt.aprintf(
					"%s:%d: %s reaches the engine through `sciter.api()`, which does not check the " +
					"thread. Use `engine()` instead - it is the same table with `guard_engine_thread` " +
					"in front of it. If this really is a call that must work from any thread, add it " +
					"to AFFINITY_EXEMPT in this file with the reason.",
					sf.path,
					site.pos.line,
					name,
				),
			)
		}
	}

	for e in AFFINITY_EXEMPT {
		if !(e.name in seen_exempt) {
			append(
				&problems,
				fmt.aprintf("AFFINITY_EXEMPT lists '%s', which no longer calls `sciter.api()` - drop it", e.name),
			)
		}
	}

	if len(problems) > 0 {
		fmt.eprintln("thread-affinity rule unenforced (docs/rules.md section 1):\n")
		for p in problems {
			fmt.eprintfln("  %s", p)
		}
		return 1
	}

	fmt.printfln(
		"ok: %d engine calls go through `engine()` and are thread-checked; %d documented exception%s",
		guarded,
		len(seen_exempt),
		len(seen_exempt) == 1 ? "" : "s",
	)
	return 0
}
