// Capabilities Odin cannot bind, driven from Odin anyway: ask the document to do it.
//
//   just example script_bridge
//   odin test examples/script_bridge.odin -file
//
// Nine of the things an application needs have **no slot in `ISciterAPI` at all** - clipboard,
// printing dialogs, file dialogs, tray icon, menus, audio, gestures, zip, storage. Grepping
// `sciter-x-api.h` for any of them returns nothing, which is a real architectural fact about Sciter
// rather than a gap in these bindings: the host API is a document and rendering API, and the
// application services live in the script runtime. See
// [`SDK-PARITY.md`](../docs/SDK-PARITY.md#capabilities-with-no-host-api-at-all).
//
// So the route is the one this file is about, and it is the *same* route for all nine - which is why
// there is one example here rather than nine. The table of which script call performs which capability
// is in
// [`calling-between-odin-and-js.md`](../docs/calling-between-odin-and-js.md#capabilities-that-only-script-can-reach).
//
// **The pattern, in three parts:**
//
//  1. **A module script stashes what `eval` cannot reach.** `Clipboard`, `Zip`, `Audio` and `Graphics`
//     are globals and `eval` sees them; `@sys`, `@env`, `@sciter` and `@storage` are *modules*, and
//     `eval("import(...)")` fails outright - measured, `expecting ')'`, because the expression
//     evaluator has no top-level `await` and no dynamic import. A `<script type="module">` in the
//     document imports them and hangs them on `globalThis`, and from then on `eval` and `call` reach
//     them like anything else.
//  2. **Odin calls a script function, not a script fragment.** `call(window, "name", args…)` passes
//     real `Value`s and gets one back, so nothing is stringified on the way in or parsed on the way
//     out. `eval` is for one-liners; `call` is the interface.
//  3. **The answer is a `Value`, so it is data.** A map, an array, a byte buffer - whatever the
//     capability produced, read with `value_get`, `value_at`, `value_to_bytes`.
//
// The capability worked through here is the **clipboard, carrying things that are not text**, chosen
// because its failure mode is more interesting than "it printed": JSON survives a round trip exactly,
// and **HTML does not**. What comes back is wrapped in `<html><!--StartFragment-->…<!--EndFragment-->
// </html>` **and carries a trailing NUL**, which is the CF_HTML convention leaking through the
// engine's own clipboard code. A host that compares what it wrote with what it read gets a surprise;
// `unwrap_clipboard_html` below is the four lines that deal with it.
//
// **"JSON survives a round trip exactly" is true on Linux and Windows and false on macOS**, measured on
// macos-14/arm64. There the write is accepted and the object is simply not there afterwards, while text
// and html round trip normally - so a host that carries structure through the clipboard needs a text
// fallback on macOS. The test below pins the difference rather than skipping it.
//
// Everything here runs in a **windowless view** - no window, no pump, no `init`. The clipboard is a
// process-wide service and does not need one, which is worth knowing if you were expecting the
// opposite. (On macOS a windowless view still stands up AppKit - see the bootstrap below - but that is
// a threading matter, not a clipboard one.)
package main

import sciter ".."
import "../sciter_app"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The bridge document. Everything Odin will call lives here; the module script is part 1 of the
// pattern, and the functions below it are part 2.
//
// `<script type="module">` rather than a plain script: `import` is only legal in a module, and the
// modules are what `eval` cannot reach on its own.
DOC :: `<html>
<head><style>
  html, body { margin:0; padding:0; width:100%; height:100%; background:#1e1e2e; color:#cdd6f4;
               font:15px system; }
  #log { margin:16px; font:13px monospace; white-space:pre-wrap; color:#a6adc8; }
</style></head>
<body>
  <div id="log">the host drives this document</div>

  <script type="module">
    // Part 1: hang the modules where eval can see them. Nothing else in this file needs to be a
    // module, and a host that only wants the globals can skip this entirely.
    import * as sys from "@sys";
    import * as env from "@env";
    import * as sciter from "@sciter";
    globalThis.modules = { sys, env, sciter };

    // Part 2: the interface. Each of these is one capability, and each returns data rather than
    // printing anything - so the host gets an answer it can act on.
    globalThis.clipboardPutText = function(text) {
      return Clipboard.writeText(text);
    };
    globalThis.clipboardGetText = function() {
      return Clipboard.readText();
    };
    globalThis.clipboardPut = function(data) {
      // data is whatever Odin built: {json:…}, {html:…}, {text:…}, {link:{caption,url}}
      return Clipboard.write(data);
    };
    globalThis.clipboardGet = function() {
      // The whole object, so the host can see which flavours survived.
      const got = Clipboard.read();
      return {
        hasText: Clipboard.has("text"),
        hasHtml: Clipboard.has("html"),
        hasJson: Clipboard.has("json"),
        text: got.text,
        html: got.html,
        json: got.json,
      };
    };

    // A capability that needs a module rather than a global, to show the stash paying for itself.
    globalThis.machine = function() {
      return {
        platform: globalThis.modules.env.PLATFORM,
        home: globalThis.modules.env.home(),
        temp: globalThis.modules.sys.tmpdir(),
        sciterVersion: globalThis.modules.sciter.VERSION,
      };
    };

    globalThis.ready = true;
  </script>
</body>
</html>`

// ---------------------------------------------------------------------------------------------------
// The Odin side
//
// Every one of these is the same three lines: build the arguments as Values, `call`, read the answer.

// Puts plain text on the clipboard. The simplest possible round trip, and the shape of all the rest.
put_text :: proc(window: sciter_app.Window, text: string) -> (ok: bool, err: sciter_app.Error) {
	argument := sciter_app.scoped_value_from_string(text)

	result := sciter_app.scoped_call(window, "clipboardPutText", argument) or_return
	return sciter_app.value_to_bool(&result)
}

// Reads it back. **Every string that comes off this clipboard carries a trailing NUL inside it** - the
// text flavour as much as the HTML one - so the trim is not optional: `"hello\x00" != "hello"`, and a
// host that compares what it wrote with what it read fails for a reason it cannot see in a log.
get_text :: proc(window: sciter_app.Window, allocator := context.allocator) -> (text: string, err: sciter_app.Error) {
	result := sciter_app.scoped_call(window, "clipboardGetText") or_return
	if sciter_app.value_is_undefined(&result) {
		return "", nil // nothing textual on the clipboard, which is not an error
	}
	raw := sciter_app.value_to_string(&result, context.temp_allocator) or_return
	return strings.clone(strings.trim_right(raw, "\x00"), allocator), nil
}

// Puts something that is *not* text. `flavour` is "json", "html", "text" or "link"; `payload` is
// whatever that flavour wants, already a Value - which is the point of doing it this way rather than
// building a string of JavaScript.
put_flavour :: proc(
	window: sciter_app.Window,
	flavour: string,
	payload: ^sciter_app.Value,
) -> (
	ok: bool,
	err: sciter_app.Error,
) {
	// A map is what a Value becomes when a key is stored in it - there is no separate constructor.
	data: sciter_app.Value
	defer sciter_app.value_clear(&data)
	sciter_app.value_set(&data, flavour, payload) or_return

	result := sciter_app.scoped_call(window, "clipboardPut", data) or_return
	return sciter_app.value_to_bool(&result)
}

// Reads everything back at once, so a caller can see which flavours the system clipboard kept.
Clipboard_Contents :: struct {
	has_text, has_html, has_json: bool,
	text, html:                   string, // allocated in the caller's allocator
	json:                         sciter_app.Value, // owns a reference; value_clear it
}

read_clipboard :: proc(
	window: sciter_app.Window,
	allocator := context.allocator,
) -> (
	contents: Clipboard_Contents,
	err: sciter_app.Error,
) {
	result := sciter_app.scoped_call(window, "clipboardGet") or_return

	flag :: proc(map_value: ^sciter_app.Value, name: string) -> bool {
		v, err := sciter_app.scoped_value_get(map_value, name)
		if err != nil {
			return false
		}
		b, _ := sciter_app.value_to_bool(&v)
		return b
	}
	str :: proc(map_value: ^sciter_app.Value, name: string, allocator: runtime.Allocator) -> string {
		v, err := sciter_app.scoped_value_get(map_value, name)
		if err != nil {
			return ""
		}
		if sciter_app.value_is_undefined(&v) {
			return ""
		}
		s, _ := sciter_app.value_to_string(&v, allocator)
		return s
	}

	contents.has_text = flag(&result, "hasText")
	contents.has_html = flag(&result, "hasHtml")
	contents.has_json = flag(&result, "hasJson")
	contents.text = str(&result, "text", allocator)
	contents.html = str(&result, "html", allocator)

	if json, jerr := sciter_app.value_get(&result, "json"); jerr == nil {
		contents.json = json // the caller clears it
	}
	return contents, nil
}

// **The trap.** HTML written to the clipboard comes back as a CF_HTML-style fragment: wrapped in
// `<html><!--StartFragment-->…<!--EndFragment--></html>` and terminated with a NUL byte that is inside
// the string, not after it. Measured on 6.0.4.9/Linux; the same convention is what Windows has always
// used, so it is the engine being consistent rather than the platform leaking.
//
// The NUL is on the text flavour too - see `get_text`. The result borrows from `html`: a slice of it,
// not a copy.
unwrap_clipboard_html :: proc(html: string) -> string {
	trimmed := strings.trim_right(html, "\x00")
	if start := strings.index(trimmed, "<!--StartFragment-->"); start >= 0 {
		trimmed = trimmed[start + len("<!--StartFragment-->"):]
	}
	if end := strings.index(trimmed, "<!--EndFragment-->"); end >= 0 {
		trimmed = trimmed[:end]
	}
	return strings.trim_space(trimmed)
}

// The module stash paying for itself: four facts that live in `@env` and `@sys`, which `eval` cannot
// import on its own.
machine_facts :: proc(
	window: sciter_app.Window,
	allocator := context.allocator,
) -> (
	facts: map[string]string,
	err: sciter_app.Error,
) {
	result := sciter_app.scoped_call(window, "machine") or_return

	facts = make(map[string]string, allocator)
	for name in ([]string{"platform", "home", "temp", "sciterVersion"}) {
		v, kerr := sciter_app.scoped_value_get(&result, name)
		if kerr != nil {
			continue
		}
		s, _ := sciter_app.value_to_display_string(&v, allocator = allocator)
		facts[strings.clone(name, allocator)] = s
	}
	return facts, nil
}

// ---------------------------------------------------------------------------------------------------

main :: proc() {
	if !sciter_app.load_engine() {
		os.exit(1)
	}
	sciter_app.set_default_debug_output()

	// **`@sys` is the one thing here that needs permission.** Without `.FILE_IO` the module still
	// imports and exports nothing but `Error` - `tmpdir` comes back "not a function" - so the failure
	// looks like a missing member rather than a refusal. Measured: everything else in this file,
	// `@env` included, works with no features set at all.
	sciter_app.set_script_features({.FILE_IO, .SYSINFO, .EVAL})

	view, err := sciter_app.create_windowless({width = 420, height = 200})
	if err != nil {
		fmt.eprintln("could not create the view:", err)
		os.exit(1)
	}
	defer sciter_app.destroy_windowless(&view)

	if lerr := sciter_app.load_html(view.window, DOC, "about:blank"); lerr != nil {
		fmt.eprintln("could not load the document:", lerr)
		os.exit(1)
	}
	// The module script runs asynchronously, so the interface is not there the instant the load
	// returns. Beat until it is - `globalThis.ready` is the flag the document sets last.
	for _ in 0 ..< 20 {
		sciter_app.windowless_heartbeat(&view, 16 * time.Millisecond)
		if ready, rerr := sciter_app.scoped_global(view.window, "ready"); rerr == nil {
			if b, _ := sciter_app.value_to_bool(&ready); b {
				break
			}
		}
	}

	// Text, which is the easy half.
	if ok, werr := put_text(view.window, "written by Odin, through the document"); werr != nil {
		fmt.eprintln("clipboard write failed:", werr)
	} else {
		fmt.println("wrote text:", ok)
	}
	if text, rerr := get_text(view.window, context.temp_allocator); rerr == nil {
		fmt.printfln("read back: %q", text)
	}

	// JSON, which is the half worth having: an arbitrary structure crosses intact.
	payload, perr := sciter_app.value_parse(`{name:"odin", counts:[1,2,3], nested:{ok:true}}`)
	if perr != nil {
		fmt.eprintln("could not build the payload:", perr)
		os.exit(1)
	}
	defer sciter_app.value_clear(&payload)
	if ok, jerr := put_flavour(view.window, "json", &payload); jerr != nil {
		fmt.eprintln("clipboard json write failed:", jerr)
	} else {
		fmt.println("wrote json:", ok)
	}

	contents, cerr := read_clipboard(view.window, context.temp_allocator)
	if cerr == nil {
		defer sciter_app.value_clear(&contents.json)
		back, _ := sciter_app.value_to_display_string(
			&contents.json,
			.JSON_LITERAL,
			allocator = context.temp_allocator,
		)
		fmt.printfln(
			"clipboard now has text=%v html=%v json=%v",
			contents.has_text,
			contents.has_html,
			contents.has_json,
		)
		fmt.printfln("json came back as: %s", back)
	}

	// HTML, which is where the surprise is.
	fragment := sciter_app.scoped_value_from_string("<b>bold</b> and <i>italic</i>")
	if _, herr := put_flavour(view.window, "html", &fragment); herr == nil {
		if got, gerr := read_clipboard(view.window, context.temp_allocator); gerr == nil {
			defer sciter_app.value_clear(&got.json)
			fmt.printfln("html as stored:   %q", got.html)
			fmt.printfln("html unwrapped:   %q", unwrap_clipboard_html(got.html))
		}
	}

	// And the modules, which is what the stash was for.
	if facts, ferr := machine_facts(view.window, context.temp_allocator); ferr == nil {
		defer delete(facts)
		for name in ([]string{"platform", "home", "temp", "sciterVersion"}) {
			fmt.printfln("%-14s %s", name, facts[name])
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// Tests

// **macOS: the engine's AppKit singleton has to be built on the main thread.** Odin's test runner runs
// every test on a `thread.Pool` worker, at any `ODIN_TEST_THREADS` count, and the first engine call
// from one aborts the process in `-[NSApplication setMainMenu:]`. `@(init)` procedures do run on the
// main thread, before the runner starts, so the singleton is built there and every later
// `sciter_app.init()` is a no-op (`g_initialized` in sciter_app/app.odin). Test binaries only: a normal
// build reaches the engine from `main`, which is the main thread by definition. See
// docs/MACOS-CHECKLIST.md section 2.
when ODIN_OS == .Darwin && ODIN_TEST {
	@(private = "file")
	@(init)
	darwin_main_thread_bootstrap :: proc "contextless" () {
		context = runtime.default_context()
		if !sciter_app.load_engine() {
			return
		}
		_ = sciter_app.init()

		// And forget the thread that just armed rule 1. That thread is `main`, every test runs on a
		// `thread.Pool` worker, and the guard would trap each one on its first engine call. The split is
		// real and unavoidable - AppKit wants main for the singleton, the runner wants a worker for the
		// tests - so what re-arming buys is the rest of the rule: the first test call arms the worker,
		// and a later call from anywhere else still traps. docs/MACOS-CHECKLIST.md section 2 has why.
		// The guard's *other* Darwin rule - that the engine's thread is the main thread - turns itself
		// off under `ODIN_TEST`, so it needs nothing here.
		sciter_app.check_thread_affinity()
	}
}

@(private = "file")
have_display :: proc() -> bool {
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		return true
	} else {
		return(
			os.get_env("DISPLAY", context.temp_allocator) != "" ||
			os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" \
		)
	}
}

// One view for the binary: a destroyed windowless view ends windowless mode for the process.
@(private = "file")
g_view: sciter_app.Windowless_View

@(private = "file")
test_view :: proc(t: ^testing.T) -> (window: sciter_app.Window, ok: bool) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here")
		return nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()
	sciter_app.set_script_features({.FILE_IO, .SYSINFO, .EVAL})

	if g_view.window == nil {
		v, err := sciter_app.create_windowless({width = 420, height = 200})
		testing.expect_value(t, err, nil)
		if err != nil {
			return nil, false
		}
		g_view = v
	}
	testing.expect_value(t, sciter_app.load_html(g_view.window, DOC, "about:blank"), nil)
	for _ in 0 ..< 20 {
		sciter_app.windowless_heartbeat(&g_view, 16 * time.Millisecond)
		if ready, rerr := sciter_app.scoped_global(g_view.window, "ready"); rerr == nil {
			if b, _ := sciter_app.value_to_bool(&ready); b {
				break
			}
		}
	}
	return g_view.window, true
}

// The whole premise: a capability with no API slot, driven from Odin and answering with data.
@(test)
test_text_round_trips_through_the_document :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	wrote, werr := put_text(window, "odin wrote this")
	testing.expect_value(t, werr, nil)
	testing.expect(t, wrote, "the clipboard accepted the text")

	back, rerr := get_text(window, context.temp_allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, back, "odin wrote this")
}

// The half that is worth the example: structure survives, and it never became a string on the way.
@(test)
test_json_survives_the_round_trip_exactly :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	payload, perr := sciter_app.scoped_value_parse(`{name:"odin", counts:[1,2,3]}`)
	testing.expect_value(t, perr, nil)

	wrote, werr := put_flavour(window, "json", &payload)
	testing.expect_value(t, werr, nil)
	testing.expect(t, wrote, "the clipboard accepted the object")

	contents, cerr := read_clipboard(window, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&contents.json)

	// **macOS accepts the object and then does not hold it.** Measured on macos-14/arm64, engine
	// 6.0.4.9: `put_flavour(..., "json", ...)` answers true - the write is not rejected - and the very
	// next `read_clipboard` reports no json flavour at all. There is then nothing to read a structure
	// out of, so every assertion in the `else` below fails against an undefined Value with
	// `INCOMPATIBLE_TYPE`, which reads like a Value bug and is not one.
	//
	// It is the `json` flavour specifically, not the clipboard: `test_text_round_trips_through_the
	// _document` passes here, and the html test below passes including its NUL assertion, which macOS
	// answers the way Linux does. So this is neither clipboard access, nor a headless session, nor a
	// permission - the other flavours use the same two calls and survive.
	//
	// Pinned rather than skipped. If a later engine starts carrying the object on macOS, this test
	// failing is the right way to hear about it. See docs/MACOS-CHECKLIST.md.
	when ODIN_OS == .Darwin {
		testing.expect(
			t,
			!contents.has_json,
			"the json flavour does not survive the round trip on macOS - if it does now, this rule changed",
		)
	} else {
		testing.expect(t, contents.has_json, "the clipboard reports it holds json")

		// Read the structure, rather than comparing rendered text - the point of carrying a Value.
		name, nerr := sciter_app.scoped_value_get(&contents.json, "name")
		testing.expect_value(t, nerr, nil)
		name_text, _ := sciter_app.value_to_string(&name, context.temp_allocator)
		testing.expect_value(t, name_text, "odin")

		counts, cerr2 := sciter_app.scoped_value_get(&contents.json, "counts")
		testing.expect_value(t, cerr2, nil)
		length, lerr := sciter_app.value_len(&counts)
		testing.expect_value(t, lerr, nil)
		testing.expect_value(t, length, 3)
	}
}

// **HTML does not survive unchanged**, and this is the test that says exactly how it differs - which is
// the finding the example exists to carry.
@(test)
test_html_comes_back_wrapped_and_nul_terminated :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	ORIGINAL :: "<b>bold</b> and <i>italic</i>"
	fragment := sciter_app.scoped_value_from_string(ORIGINAL)

	wrote, werr := put_flavour(window, "html", &fragment)
	testing.expect_value(t, werr, nil)
	testing.expect(t, wrote, "the clipboard accepted the fragment")

	contents, cerr := read_clipboard(window, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&contents.json)
	testing.expect(t, contents.has_html, "the clipboard reports it holds html")

	// Not what went in.
	testing.expect(t, contents.html != ORIGINAL, "html is not returned verbatim - if it is, this rule changed")
	testing.expect(t, strings.contains(contents.html, "<!--StartFragment-->"), "the CF_HTML wrapper is there")
	testing.expect(t, strings.contains(contents.html, "\x00"), "and a NUL is inside the string")

	// **On Linux the NUL is not an HTML thing - the text flavour has it too. On Windows it is.** The
	// CF_HTML wrapper and its NUL come back from the HTML flavour on both platforms; the plain text
	// flavour is clean on Windows and NUL-terminated on Linux. So `get_text`'s trim is load-bearing on
	// Linux and a no-op on Windows, and it stays unconditional: trimming a NUL that is not there costs
	// nothing, and a host that skipped it would compare unequal to what it wrote on one platform only.
	wrote_text, terr := put_flavour(window, "text", &fragment)
	testing.expect_value(t, terr, nil)
	testing.expect(t, wrote_text, "the clipboard accepted the text flavour")
	plain, perr := read_clipboard(window, context.temp_allocator)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&plain.json)
	when ODIN_OS == .Windows {
		testing.expect(t, !strings.contains(plain.text, "\x00"), "the text flavour is clean here")
	} else {
		testing.expect(t, strings.contains(plain.text, "\x00"), "the text flavour carries the NUL too")
	}

	// And what to do about it.
	testing.expect_value(t, unwrap_clipboard_html(contents.html), ORIGINAL)
}

// Part 1 of the pattern, and the reason it exists: `eval` cannot import a module, so a module script
// has to put them somewhere `eval` can see.
@(test)
test_eval_cannot_import_but_the_stash_can :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	// The direct route fails - and fails as a *parse*, not as a permission error, which is why no
	// amount of `set_script_features` fixes it.
	result, err := sciter_app.scoped_eval(window, `await import("@sys")`)
	if err == nil {
		text, _ := sciter_app.value_to_display_string(&result, allocator = context.temp_allocator)
		testing.expect(t, strings.contains(text, "expecting"), "eval should refuse a dynamic import")
	}

	// The stashed route works, and carries real values out of `@env` and `@sys`.
	facts, ferr := machine_facts(window, context.temp_allocator)
	testing.expect_value(t, ferr, nil)
	defer delete(facts)
	testing.expect(t, facts["platform"] != "", "@env.PLATFORM answered")
	testing.expect(t, facts["home"] != "", "@env.home() answered")
	testing.expect(t, facts["temp"] != "", "@sys.tmpdir() answered")
	testing.expect(t, strings.contains(facts["sciterVersion"], "."), "@sciter.VERSION looks like a version")
}

// ---------------------------------------------------------------------------------------------------
// Engine options
//
// `set_script_features` above is one line over `set_option`, and these two tests are about the raw call
// underneath it: what its untyped `uintptr` value really carries, and which options this engine will
// take at all.

// **`.SET_INIT_SCRIPT` is the option that shows why the value is untyped**: it is a pointer to UTF-8
// source, not a number, and the script runs in every document loaded afterwards - before that
// document's own scripts. It is also the way to publish something into `globalThis` that does not go
// through `set_global`.
//
// Measured on 6.0.4.9: setting it again *replaces* the previous script rather than adding to it, and a
// document loaded before the call never sees it. Both are pinned below.
//
// The free-then-scribble is the actual test of the header's "the engine copies this string inside the
// call": the source is freed and its bytes are overwritten before the document that runs it is loaded.
@(test)
test_an_init_script_set_through_set_option_runs_in_every_later_document :: proc(t: ^testing.T) {
	if !have_display() {
		fmt.println("skipping - a windowless view still needs a display here")
		return
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}

	// **Not optional on Windows, and the reason is not obvious.** With no host handler installed the
	// engine reports parse errors and script diagnostics through `OutputDebugStringW`, which Windows
	// implements by *raising an exception* (DBG_PRINTEXCEPTION_WIDE_C, 0x4001000A). Odin's test runner
	// installs a handler that treats any exception as fatal to the test, so a CSS warning killed the
	// test that provoked it and every test after it in the file - reported as `Signal caught: Unknown`,
	// which reads like a segfault and is not one. Routing diagnostics to a callback avoids the API
	// entirely. Harmless on Linux, where it just makes the engine's warnings visible.
	sciter_app.set_default_debug_output()
	context.allocator = runtime.default_allocator()

	// Leave the engine as it was found: every later test in this file loads a document too.
	defer {
		empty := strings.clone_to_cstring("", context.temp_allocator)
		testing.expect_value(t, sciter_app.set_option(.SET_INIT_SCRIPT, uintptr(rawptr(empty))), nil)
	}

	SOURCE :: "globalThis.initMark = 4321;"
	src := strings.clone_to_cstring(SOURCE)
	testing.expect_value(t, sciter_app.set_option(.SET_INIT_SCRIPT, uintptr(rawptr(src))), nil)

	// Freed, and the block filled with something that is not the script. If the engine had kept the
	// pointer rather than the bytes, the document below would run this instead.
	delete(src)
	scribble := make([]u8, len(SOURCE) + 1)
	defer delete(scribble)
	for &b in scribble {b = 'X'}

	window, ok := test_view(t)
	if !ok {return}

	mark, err := sciter_app.scoped_eval(window, "globalThis.initMark")
	testing.expect_value(t, err, nil)
	n, nerr := sciter_app.value_to_int(&mark)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, n, 4321)

	// Replaced, not accumulated: the second script runs and the first global is gone.
	second := strings.clone_to_cstring("globalThis.initMark = 8642;", context.temp_allocator)
	testing.expect_value(t, sciter_app.set_option(.SET_INIT_SCRIPT, uintptr(rawptr(second))), nil)

	window2, ok2 := test_view(t)
	if !ok2 {return}

	again, aerr := sciter_app.scoped_eval(window2, "globalThis.initMark")
	testing.expect_value(t, aerr, nil)
	n2, _ := sciter_app.value_to_int(&again)
	testing.expect_value(t, n2, 8642)
}

// **The header's "hWnd = N/A" comments do not say which options need a window, and four of them are
// refused outright.** `Sciter_Rt_Options` annotates only some entries with `hWnd`, and `.SMOOTH_SCROLL`
// - annotated `value:TRUE - enable, value:FALSE - disable, enabled by default` and nothing else - is
// refused with a nil window and accepted with one. So a nil `window` is not the safe default the
// comment on `set_option` would suggest; it is the one to try second.
//
// Measured on 6.0.4.9 on Linux and on Windows. Most of what was guarded as Linux-specific turned out
// not to be - `.SMOOTH_SCROLL` needs a window on both, and `.FONT_SMOOTHING` and `.ENABLE_UIAUTOMATION`
// are refused on both, the last of those despite being a Windows feature. What actually differs is the
// HTTP client pair, `.CONNECTION_TIMEOUT` and `.HTTPS_ERROR`: refused on Linux, accepted on Windows.
// The guard is now around that pair and the three window-shape options that exist only on Windows.
@(test)
test_which_options_this_engine_takes_and_which_it_refuses :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	// An option code the engine has never heard of is refused rather than ignored, which is what makes
	// the return value worth checking at all.
	testing.expect_value(
		t,
		sciter_app.set_option(sciter.Sciter_Rt_Options(999), 0),
		sciter_app.Error(sciter_app.Api_Error.Option_Failed),
	)

	// The genuinely process-wide ones, all accepted with no window.
	process_wide := []sciter.Sciter_Rt_Options {
		.SET_SCRIPT_RUNTIME_FEATURES,
		.SET_DEBUG_MODE,
		.SET_UX_THEMING,
		.SET_MAX_HTTP_DATA_LENGTH,
		.USE_INTERNAL_HTTP_CLIENT,
	}
	for option in process_wide {
		testing.expectf(t, sciter_app.set_option(option, 1) == nil, "%v should be accepted", option)
	}

	// Needs a window, despite reading like a global preference. Measured the same on Linux and Windows,
	// so it is not a property of one build after all.
	testing.expect_value(
		t,
		sciter_app.set_option(.SMOOTH_SCROLL, 1),
		sciter_app.Error(sciter_app.Api_Error.Option_Failed),
	)
	testing.expect_value(t, sciter_app.set_option(.SMOOTH_SCROLL, 1, window), nil)

	// Refused either way, on both builds: the option is in the header and implemented in neither.
	// `.ENABLE_UIAUTOMATION` is the surprise of the pair - it is a Windows feature, and the Windows build
	// refuses it exactly as Linux does.
	for option in ([]sciter.Sciter_Rt_Options{.FONT_SMOOTHING, .ENABLE_UIAUTOMATION}) {
		testing.expectf(t, sciter_app.set_option(option, 1) != nil, "%v with no window", option)
		testing.expectf(t, sciter_app.set_option(option, 1, window) != nil, "%v with a window", option)
	}

	// The two that genuinely differ, which is what the guard is for. Both are HTTP-client settings, and
	// the split follows the client: Linux uses the system one and has nothing to configure, Windows uses
	// the internal one and takes them.
	when ODIN_OS == .Linux {
		for option in ([]sciter.Sciter_Rt_Options{.CONNECTION_TIMEOUT, .HTTPS_ERROR}) {
			testing.expectf(t, sciter_app.set_option(option, 1) != nil, "%v with no window", option)
			testing.expectf(t, sciter_app.set_option(option, 1, window) != nil, "%v with a window", option)
		}
	} else when ODIN_OS == .Windows {
		for option in ([]sciter.Sciter_Rt_Options{.CONNECTION_TIMEOUT, .HTTPS_ERROR}) {
			testing.expectf(t, sciter_app.set_option(option, 1) == nil, "%v with no window", option)
			testing.expectf(t, sciter_app.set_option(option, 1, window) == nil, "%v with a window", option)
		}

		// The window-shape options, which exist only here. All three read like global preferences and
		// all three are refused without a window, the same way `.SMOOTH_SCROLL` is - so "needs a window"
		// is the rule and the header's `hWnd = N/A` annotations are the exception worth distrusting.
		for option in ([]sciter.Sciter_Rt_Options{.TRANSPARENT_WINDOW, .ALPHA_WINDOW, .SET_MAIN_WINDOW}) {
			testing.expectf(t, sciter_app.set_option(option, 1) != nil, "%v with no window", option)
			testing.expectf(t, sciter_app.set_option(option, 1, window) == nil, "%v with a window", option)
		}
	}
}
