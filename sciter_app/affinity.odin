// Thread affinity, checked rather than documented.
//
// `docs/rules.md` §1 is the package's first rule: every call has to come from the thread that ran
// `init`, and the engine offers no locking and no "call from any thread" mode. It is also the only one
// of the five rules with nothing enforcing it - ownership has `just check-ownership`, leaks have `just
// leak-check`, the documented counts have `just stats --check`, and this had a paragraph.
//
// That asymmetry is worth closing because of how the rule fails. A leak is slow and visible; an
// over-release is a segfault with the call site on the stack. Calling from the wrong thread is neither:
// it corrupts engine state and surfaces later, somewhere else, as a crash whose backtrace contains
// nothing that did anything wrong. The one moment when the guilty call *is* on the stack is when it
// happens, and this is what stands there.
//
// **Debug builds only.** Without `-debug` every procedure here compiles to nothing, exactly as
// `tracking.odin` does, so a release build pays neither the load nor the branch.
//
// **It fires before the call, and it covers all of them.** The chokepoint is `engine()` in
// `sciter_app.odin`, which every procedure in the package goes through to reach the function table, so
// the guard runs while the offending call is still on the stack and before the engine has been touched.
// `post_callback` is the single exception, deliberately: it is rule 1's way across and is meant to be
// called from anywhere.
//
// It did not start that way, and the history is the argument for the current shape. The guard first sat
// in the four error-wrapping helpers and the two sub-table accessors, which meant it saw a call only if
// that call returned a result code. Measured: 124 of 199 engine call sites, and the 75 it missed were
// the ones whose engine call returns a bare `SBOOL` - `eval`, `call`, `load_html`, `create_window`,
// `close`, every constructor in `value.odin`, the whole windowless surface, and `init`. Fifty
// `value_from_string` calls from a worker thread reported zero violations. Worse, because `init` was
// among the misses, the armed thread was whichever thread first reached a *guarded* call rather than
// the thread that ran `init` - so a worker could arm itself as the engine's thread and the real engine
// thread would then be the one that trapped. `docs/review/10-threading.md` has both measurements.
package sciter_app

// Both are used only inside `when ODIN_DEBUG`, so a release build reports them unused without this -
// the same reason `examples/api_map.odin` marks its UTF-16 import.
@(require) import "base:runtime"
@(require) import "core:sync"

when ODIN_DEBUG {
	@(private = "file")
	Affinity :: struct {
		on:          bool,
		strict:      bool,
		main_thread: bool, // Darwin: the armed thread must also be *the* main thread
		id:          int, // 0 until the first guarded call arms it
		violations:  int,
	}

	@(private = "file")
	g_affinity := Affinity {
		on          = true,
		strict      = true,
		main_thread = ODIN_OS == .Darwin && !ODIN_TEST,
	}

	// **macOS needs a stronger rule than the other two platforms, and this is how it is checked.**
	// Rule 1 is consistency - every call on whichever thread came first - and on Darwin that is not
	// enough: `init`, `create_image` and `create_windowless` all construct the engine's
	// `xwing::application` singleton, which builds `NSApplication`, and `create_window` reaches
	// `NSWindow`. AppKit aborts the process for either off the main thread. A program that runs the
	// engine on one consistent *worker* thread therefore satisfies rule 1, satisfies the rest of this
	// file, and dies in AppKit with a trace naming Apple's code and none of its own
	// (docs/MACOS-CHECKLIST.md section 2 has one).
	//
	// `@(init)` is what makes this cheap: those procedures run at start-up, before `main`, on the
	// process's first thread - verified directly on macOS by comparing thread ids in a probe, which is
	// also the fact the Darwin test bootstrap is built on. So the main thread's id can be recorded with
	// no platform API, no `foreign import` and nothing to link.
	//
	// **Off in a test binary, `&& !ODIN_TEST` above.** Odin's runner builds a `thread.Pool` and submits
	// every test to it, at any `ODIN_TEST_THREADS` count, keeping the main thread for its own loop - so
	// no test on macOS can satisfy this rule, and a default that no test can satisfy is a default that
	// fails every macOS test binary rather than a check. That is not a guess: it shipped that way for
	// one CI run, and `archive` and `single_binary` - the two examples whose tests touch the engine
	// without going through the windowed bootstrap - trapped on their first call. `ODIN_TEST` is a
	// build-level constant, visible here and not only in the `main` package, which is what makes this
	// the whole fix rather than a per-example opt-out.
	@(private = "file")
	g_main_thread: int

	@(private = "file")
	@(init)
	record_main_thread :: proc "contextless" () {
		g_main_thread = sync.current_thread_id()
	}
}

// Turns the affinity check on or off, and forgets whichever thread was armed.
//
// It is **on and strict by default in a debug build**: the first guarded call records the thread it
// happens on, and any later call from another thread traps there and then. That default is deliberate -
// a check nobody switches on is the same as no check - and there are two reasons to change it:
//
//   - `strict = false` counts violations instead of trapping, which is what a test that provokes one
//     needs. `thread_affinity_violations` reads the count.
//   - `on = false` for a test runner told to use several threads. Odin's runner may hand consecutive
//     tests to different threads, and this package's own suite passes `-define:ODIN_TEST_THREADS=1` for
//     that reason. It is the engine's rule, not this package's invention, so the honest fix is one
//     thread rather than a disabled check.
//
// `main_thread` is the macOS half: it adds "and that thread must be the process's main thread" to the
// rule, because AppKit requires it and rule 1 on its own does not - see the note beside `g_main_thread`.
// The default matches the state that field starts in, on for a macOS **program** and off for everything
// else, a macOS *test binary* included. Pass it explicitly to measure the check itself, which is how it
// was tested from Windows.
//
// Calling it also re-arms: the next guarded call decides which thread is the engine's.
check_thread_affinity :: proc(on := true, strict := true, main_thread := ODIN_OS == .Darwin && !ODIN_TEST) {
	when ODIN_DEBUG {
		// One field at a time, atomically, rather than a whole-struct assignment. The guard reads these
		// from whatever thread it happens to be on, so a plain store races those reads - and this is the
		// one file whose job is to be right about that. `on` is cleared first and set last, so the window
		// in which the other three are in flux is a window in which the check is off.
		sync.atomic_store(&g_affinity.on, false)
		sync.atomic_store(&g_affinity.id, 0)
		sync.atomic_store(&g_affinity.violations, 0)
		sync.atomic_store(&g_affinity.strict, strict)
		sync.atomic_store(&g_affinity.main_thread, main_thread)
		sync.atomic_store(&g_affinity.on, on)
	}
}

// The thread the engine was first called from, or 0 if nothing has armed it yet. Always 0 in a release
// build.
engine_thread_id :: proc() -> int {
	when ODIN_DEBUG {
		return sync.atomic_load(&g_affinity.id)
	} else {
		return 0
	}
}

// How many calls have come from the wrong thread since the check was last turned on. Only ever above
// zero with `strict = false`, because a strict check traps at the first one.
thread_affinity_violations :: proc() -> int {
	when ODIN_DEBUG {
		return sync.atomic_load(&g_affinity.violations)
	} else {
		return 0
	}
}

// The same check the wrapper makes, for your own code: put it at the top of anything that assumes it is
// on the engine's thread - a helper called from both a handler and a worker, the body of a callback you
// were handed by something else, the place where a queue is drained.
//
//	on_rows_ready :: proc(app: ^App) {
//	    sciter_app.assert_engine_thread()   // nothing below this line is safe from a worker
//	    ...
//	}
//
// A no-op in a release build.
assert_engine_thread :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		guard_engine_thread(loc)
	}
}

// Arms on first use, then compares.
//
// **First use, not `init`.** A windowed application arms here on the `init` inside it, which is what
// `docs/rules.md` §1 promises - but a windowless program never calls `init` at all
// (`examples/script_bridge.odin` and `examples/leak_sweep.odin` are both like that), and a guard that
// only worked for windowed applications would be off exactly where the threading is hardest. First use
// gets both, now that `engine()` puts `init` among the guarded calls rather than ahead of them.
@(private)
guard_engine_thread :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		if !sync.atomic_load(&g_affinity.on) {
			return
		}
		me := sync.current_thread_id()

		// The first guarded call wins. Compare-and-exchange rather than a plain store so that two
		// threads racing to be first cannot both think they are.
		if _, armed := sync.atomic_compare_exchange_strong(&g_affinity.id, 0, me); armed {
			if sync.atomic_load(&g_affinity.main_thread) && me != g_main_thread {
				sync.atomic_add(&g_affinity.violations, 1)
				if !sync.atomic_load(&g_affinity.strict) {
					return
				}
				runtime.print_string("\nsciter_app: the engine is being used from thread ")
				runtime.print_int(me)
				runtime.print_string(", but this platform requires the main thread (")
				runtime.print_int(g_main_thread)
				runtime.print_string(
					")\n  macOS builds the engine's NSApplication singleton on the first call - `init`," +
					" `create_image` and\n  `create_windowless` all reach it - and AppKit aborts the" +
					" process off the main thread. This\n  traps here instead, where the call is still on" +
					" the stack. See docs/rules.md rule 1 and\n  docs/MACOS-CHECKLIST.md section 2." +
					" `check_thread_affinity(main_thread = false)` is the way out\n  for a test binary," +
					" whose tests never run on the main thread.\n  at ",
				)
				runtime.print_caller_location(loc)
				runtime.print_string("\n")
				runtime.trap()
			}
			return
		}
		if sync.atomic_load(&g_affinity.id) == me {
			return
		}

		sync.atomic_add(&g_affinity.violations, 1)
		if !sync.atomic_load(&g_affinity.strict) {
			return
		}
		runtime.print_string("\nsciter_app: called from thread ")
		runtime.print_int(me)
		runtime.print_string(", but the engine belongs to thread ")
		runtime.print_int(sync.atomic_load(&g_affinity.id))
		runtime.print_string(
			"\n  every call must be on the thread that first used the engine - see docs/rules.md rule 1.\n" +
			"  `post_callback` is the only exception; `docs/threading.md` is the way across.\n  at ",
		)
		runtime.print_caller_location(loc)
		runtime.print_string("\n")
		runtime.trap()
	}
}
