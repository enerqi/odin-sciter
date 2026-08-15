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
// Two things it does not claim to be:
//
//   - **It fires on the way out for the DOM, Value and window calls**, because the chokepoint it sits
//     in is the error-wrapping helper that runs after the engine returns. The damage, if any, is
//     already done; what the guard buys is that you learn about it now, at this call, rather than three
//     frames into an unrelated crash. The graphics and request tables are checked on the way *in*,
//     because those calls go through an accessor rather than a result.
//   - **It is not complete.** Procedures that call the engine and return nothing - `post_callback`
//     excepted, which is meant to be called from anywhere - do not pass through a chokepoint. The
//     coverage is the ~200 call sites that do, which is most of what an application touches.
package sciter_app

// Both are used only inside `when ODIN_DEBUG`, so a release build reports them unused without this -
// the same reason `examples/api_map.odin` marks its UTF-16 import.
@(require) import "base:runtime"
@(require) import "core:sync"

when ODIN_DEBUG {
	@(private = "file")
	Affinity :: struct {
		on:         bool,
		strict:     bool,
		id:         int, // 0 until the first guarded call arms it
		violations: int,
	}

	@(private = "file")
	g_affinity := Affinity {
		on     = true,
		strict = true,
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
// Calling it also re-arms: the next guarded call decides which thread is the engine's.
check_thread_affinity :: proc(on := true, strict := true) {
	when ODIN_DEBUG {
		g_affinity = Affinity {
			on     = on,
			strict = strict,
		}
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

// The chokepoint. Arms on first use, then compares.
//
// Arming on first use rather than in `init` is deliberate: a windowless program never calls `init` -
// `examples/script_bridge.odin` and `examples/leak_sweep.odin` are both like that - and a guard that
// only works for windowed applications would be off exactly where the threading is hardest.
@(private)
guard_engine_thread :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		if !g_affinity.on {
			return
		}
		me := sync.current_thread_id()

		// The first guarded call wins. Compare-and-exchange rather than a plain store so that two
		// threads racing to be first cannot both think they are.
		if _, armed := sync.atomic_compare_exchange_strong(&g_affinity.id, 0, me); armed {
			return
		}
		if sync.atomic_load(&g_affinity.id) == me {
			return
		}

		sync.atomic_add(&g_affinity.violations, 1)
		if !g_affinity.strict {
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
