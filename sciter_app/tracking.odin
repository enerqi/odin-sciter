// Debug-build tracking for the resources that live inside the engine.
//
// `mem.Tracking_Allocator` already answers "did I leak any Odin memory", and everything this package
// allocates on your behalf - strings, slices, assets, a windowless surface - is visible to it. None of
// it can see an engine resource: a `Value`'s reference, an element reference, a taken request, an
// `Image`. Those are counted by the engine, in the engine's memory, and a leaked one shows up as a
// process that grows and nothing else. Measured, the cost is real - 2000 discarded `eval`s of a 100 kB
// string grow the process by 390 MB.
//
// So this is the same ergonomic, for the other half:
//
//	sciter_app.track_resources(true)
//	defer sciter_app.report_leaked_resources()      // prints what was never released, with its call site
//	// ... run the application, or one test ...
//
// **It compiles to nothing unless `-debug` is set.** Every entry point below is `when !ODIN_DEBUG`
// empty, so a release build carries no map, no lock and no branch.
//
// ## What it can and cannot tell you
//
// The engine's resources come in two shapes, and the difference decides how good the answer is.
//
// **Handles are tracked exactly.** An `Element`, `Node`, `Request`, `Image`, `Path`, `Text` or
// `Archive` is a pointer, so the ledger is keyed on it and a leak names the exact handle and the call
// site that acquired it. That is the whole diagnosis.
//
// **Values are counted, not identified.** A `Value` is 16 bytes passed *by value*: its address is
// whatever stack slot it currently occupies, and `value_copy` makes two Values sharing one payload, so
// neither the address nor the payload is a unique identity. What is tracked is therefore the number of
// references owed and the sites that acquired them - "nine outstanding, from these three places" rather
// than "this object leaked". It is enough to find the site, which in practice is the question.
//
// Two obligations that are not memory at all are tracked the same way, because both are currently fatal
// rather than diagnosable: the graphics state stack (an unbalanced `save_state` aborts the process) and
// a `.DELAYED` load request that is never answered.
package sciter_app

import "base:runtime"

// What kind of resource a ledger entry describes.
Resource_Kind :: enum {
	Value, // counted, not identified - see the file header
	Element, // use_element / make_element / clone_element / remove_element(finalize = false)
	Node, // node_add_ref / make_text_node / make_comment_node
	Request, // take_request / use_request
	Image,
	Path,
	Text,
	Archive,
	Graphics_State, // save_state, balanced by restore_state
	Delayed_Request, // .DELAYED returned from on_load_data, answered by data_ready_async
}

when ODIN_DEBUG {
	@(private = "file")
	Acquisition :: struct {
		kind:  Resource_Kind,
		loc:   runtime.Source_Code_Location,
		count: int, // >1 only for the counted kinds, which share a single entry
	}

	@(private = "file")
	Tracker :: struct {
		on:       bool,
		handles:  map[rawptr]Acquisition, // the identified kinds
		counted:  [Resource_Kind]int, // outstanding, for every kind
		sites:    map[runtime.Source_Code_Location]int, // where the counted ones came from
		released: [Resource_Kind]int,
	}

	@(private = "file")
	g_tracker: Tracker
}

// Turns tracking on or off, and clears whatever was recorded. A no-op in a release build.
//
// Call it once, early, on the engine's thread - the ledger has no locking for the same reason the two
// cached API tables have none (see docs/rules.md rule 1).
track_resources :: proc(on := true) {
	when ODIN_DEBUG {
		if g_tracker.on {
			delete(g_tracker.handles)
			delete(g_tracker.sites)
		}
		g_tracker = Tracker {
			on = on,
		}
		if on {
			g_tracker.handles = make(map[rawptr]Acquisition)
			g_tracker.sites = make(map[runtime.Source_Code_Location]int)
		}
	}
}

// Records the acquisition of an identified resource. `handle` is the engine's pointer.
@(private)
track_acquire :: proc(kind: Resource_Kind, handle: rawptr, loc: runtime.Source_Code_Location = #caller_location) {
	when ODIN_DEBUG {
		if !g_tracker.on || handle == nil {
			return
		}
		g_tracker.counted[kind] += 1
		if existing, found := &g_tracker.handles[handle]; found {
			// A second reference to the same handle - `use_element` twice, say. Both are owed back.
			existing.count += 1
			return
		}
		g_tracker.handles[handle] = Acquisition {
			kind  = kind,
			loc   = loc,
			count = 1,
		}
	}
}

// Records the release of an identified resource.
@(private)
track_release :: proc(kind: Resource_Kind, handle: rawptr) {
	when ODIN_DEBUG {
		if !g_tracker.on || handle == nil {
			return
		}
		g_tracker.counted[kind] -= 1
		g_tracker.released[kind] += 1
		if existing, found := &g_tracker.handles[handle]; found {
			existing.count -= 1
			if existing.count <= 0 {
				delete_key(&g_tracker.handles, handle)
			}
		}
	}
}

// Records the acquisition of a counted resource - a `Value` reference, or one of the two balance
// obligations. There is no handle to key on; the site is what gets remembered.
@(private)
track_acquire_counted :: proc(kind: Resource_Kind, loc: runtime.Source_Code_Location = #caller_location) {
	when ODIN_DEBUG {
		if !g_tracker.on {
			return
		}
		g_tracker.counted[kind] += 1
		g_tracker.sites[loc] += 1
	}
}

@(private)
track_release_counted :: proc(kind: Resource_Kind) {
	when ODIN_DEBUG {
		if !g_tracker.on {
			return
		}
		g_tracker.counted[kind] -= 1
		g_tracker.released[kind] += 1
	}
}

// What is outstanding right now, per kind. Zero everywhere in a release build.
//
// A negative count is worth acting on rather than ignoring: it means more releases than acquisitions,
// which for a reference-counted engine resource is the under-flow that segfaults - see `use_element`
// and `Owned_Request`.
outstanding_resources :: proc() -> (counts: [Resource_Kind]int) {
	when ODIN_DEBUG {
		counts = g_tracker.counted
	}
	return
}

// Prints everything still outstanding, and returns how many there were.
//
// Identified resources are listed one per line with the site that acquired them. Counted ones are
// summarised per acquiring site, because a `Value` has no identity to report - see the file header.
//
// Returns 0 in a release build, so `assert(report_leaked_resources() == 0)` is safe to leave in a test.
report_leaked_resources :: proc() -> (leaked: int) {
	when ODIN_DEBUG {
		if !g_tracker.on {
			return 0
		}

		for kind in Resource_Kind {
			if n := g_tracker.counted[kind]; n != 0 {
				leaked += n if n > 0 else -n
			}
		}
		if leaked == 0 {
			return 0
		}

		runtime.print_string("\n--- sciter_app: engine resources still outstanding ---\n")
		for kind in Resource_Kind {
			n := g_tracker.counted[kind]
			if n == 0 {
				continue
			}
			runtime.print_string("  ")
			runtime.print_type(type_info_of(Resource_Kind))
			runtime.print_string(".")
			runtime.print_string(resource_kind_name(kind))
			runtime.print_string(": ")
			runtime.print_int(n)
			if n < 0 {
				runtime.print_string("  <- MORE RELEASES THAN ACQUISITIONS: this is the under-flow that segfaults")
			}
			runtime.print_string("\n")
		}

		for handle, acq in g_tracker.handles {
			runtime.print_string("    ")
			runtime.print_string(resource_kind_name(acq.kind))
			runtime.print_string(" ")
			runtime.print_uintptr(uintptr(handle))
			runtime.print_string(" acquired at ")
			runtime.print_caller_location(acq.loc)
			runtime.print_string("\n")
		}
		for site, n in g_tracker.sites {
			runtime.print_string("    ")
			runtime.print_int(n)
			runtime.print_string(" acquired at ")
			runtime.print_caller_location(site)
			runtime.print_string("\n")
		}
		runtime.print_string("--- end ---\n")
	}
	return
}

// Whether a Value holds a reference to something in the engine, or is entirely inline.
//
// This is what keeps the `Value` counter meaningful. `value_from_int` and friends produce a Value that
// owns nothing - clearing it is a no-op and *not* clearing it costs nothing - so counting those would
// bury a real leak under hundreds of harmless ones. Only the types whose payload is engine memory are
// counted: strings, containers, functions, byte blobs, script objects and resources.
//
// `.ASSET` is deliberately absent. `value_from_asset` is a bare `ValueInt64DataSet` - the engine does
// not add_ref, so the Value owns nothing and the asset has to outlive it (see `value_from_asset`).
@(private)
value_owns_reference :: proc(v: ^Value) -> bool {
	type, _ := value_type(v)
	#partial switch type {
	case .STRING, .ARRAY, .MAP, .FUNCTION, .BYTES, .OBJECT, .RESOURCE:
		return true
	}
	return false
}

// Records a Value that came out of the engine owning a reference, and hands it straight back, so a
// producer reads `return tracked(v), nil`.
@(private)
tracked :: proc(v: Value, loc: runtime.Source_Code_Location = #caller_location) -> Value {
	when ODIN_DEBUG {
		v := v
		if value_owns_reference(&v) {
			track_acquire_counted(.Value, loc)
		}
	}
	return v
}

@(private = "file")
resource_kind_name :: proc(kind: Resource_Kind) -> string {
	switch kind {
	case .Value:
		return "Value"
	case .Element:
		return "Element"
	case .Node:
		return "Node"
	case .Request:
		return "Request"
	case .Image:
		return "Image"
	case .Path:
		return "Path"
	case .Text:
		return "Text"
	case .Archive:
		return "Archive"
	case .Graphics_State:
		return "Graphics_State"
	case .Delayed_Request:
		return "Delayed_Request"
	}
	return "?"
}
