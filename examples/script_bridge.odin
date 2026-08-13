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
// Everything here runs in a **windowless view** - no window, no pump, no `init`. The clipboard is a
// process-wide service and does not need one, which is worth knowing if you were expecting the
// opposite.
package main

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
	argument := sciter_app.value_from_string(text)
	defer sciter_app.value_clear(&argument)

	result := sciter_app.call(window, "clipboardPutText", argument) or_return
	defer sciter_app.value_clear(&result)
	return sciter_app.value_to_bool(&result)
}

// Reads it back. **Every string that comes off this clipboard carries a trailing NUL inside it** - the
// text flavour as much as the HTML one - so the trim is not optional: `"hello\x00" != "hello"`, and a
// host that compares what it wrote with what it read fails for a reason it cannot see in a log.
get_text :: proc(window: sciter_app.Window, allocator := context.allocator) -> (text: string, err: sciter_app.Error) {
	result := sciter_app.call(window, "clipboardGetText") or_return
	defer sciter_app.value_clear(&result)
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

	result := sciter_app.call(window, "clipboardPut", data) or_return
	defer sciter_app.value_clear(&result)
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
	result := sciter_app.call(window, "clipboardGet") or_return
	defer sciter_app.value_clear(&result)

	flag :: proc(map_value: ^sciter_app.Value, name: string) -> bool {
		v, err := sciter_app.value_get(map_value, name)
		if err != nil {
			return false
		}
		defer sciter_app.value_clear(&v)
		b, _ := sciter_app.value_to_bool(&v)
		return b
	}
	str :: proc(map_value: ^sciter_app.Value, name: string, allocator: runtime.Allocator) -> string {
		v, err := sciter_app.value_get(map_value, name)
		if err != nil {
			return ""
		}
		defer sciter_app.value_clear(&v)
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
	result := sciter_app.call(window, "machine") or_return
	defer sciter_app.value_clear(&result)

	facts = make(map[string]string, allocator)
	for name in ([]string{"platform", "home", "temp", "sciterVersion"}) {
		v, kerr := sciter_app.value_get(&result, name)
		if kerr != nil {
			continue
		}
		defer sciter_app.value_clear(&v)
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

	if err := sciter_app.load_html(view.window, DOC, "about:blank"); err != nil {
		fmt.eprintln("could not load the document:", err)
		os.exit(1)
	}
	// The module script runs asynchronously, so the interface is not there the instant the load
	// returns. Beat until it is - `globalThis.ready` is the flag the document sets last.
	for _ in 0 ..< 20 {
		sciter_app.windowless_heartbeat(&view, 16 * time.Millisecond)
		if ready, rerr := sciter_app.global(view.window, "ready"); rerr == nil {
			defer sciter_app.value_clear(&ready)
			if b, _ := sciter_app.value_to_bool(&ready); b {
				break
			}
		}
	}

	// Text, which is the easy half.
	if ok, err := put_text(view.window, "written by Odin, through the document"); err != nil {
		fmt.eprintln("clipboard write failed:", err)
	} else {
		fmt.println("wrote text:", ok)
	}
	if text, err := get_text(view.window, context.temp_allocator); err == nil {
		fmt.printfln("read back: %q", text)
	}

	// JSON, which is the half worth having: an arbitrary structure crosses intact.
	payload, perr := sciter_app.value_parse(`{name:"odin", counts:[1,2,3], nested:{ok:true}}`)
	if perr != nil {
		fmt.eprintln("could not build the payload:", perr)
		os.exit(1)
	}
	defer sciter_app.value_clear(&payload)
	if ok, err := put_flavour(view.window, "json", &payload); err != nil {
		fmt.eprintln("clipboard json write failed:", err)
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
	fragment := sciter_app.value_from_string("<b>bold</b> and <i>italic</i>")
	defer sciter_app.value_clear(&fragment)
	if _, err := put_flavour(view.window, "html", &fragment); err == nil {
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
		fmt.println("no DISPLAY or WAYLAND_DISPLAY - skipping; a windowless view still needs one")
		return nil, false
	}
	if !sciter_app.load_engine() {
		testing.fail_now(t, "the Sciter engine is not loadable - set SCITER_LIB")
	}
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
		if ready, rerr := sciter_app.global(g_view.window, "ready"); rerr == nil {
			defer sciter_app.value_clear(&ready)
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

	payload, perr := sciter_app.value_parse(`{name:"odin", counts:[1,2,3]}`)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&payload)

	wrote, werr := put_flavour(window, "json", &payload)
	testing.expect_value(t, werr, nil)
	testing.expect(t, wrote, "the clipboard accepted the object")

	contents, cerr := read_clipboard(window, context.temp_allocator)
	testing.expect_value(t, cerr, nil)
	defer sciter_app.value_clear(&contents.json)
	testing.expect(t, contents.has_json, "the clipboard reports it holds json")

	// Read the structure, rather than comparing rendered text - the point of carrying a Value.
	name, nerr := sciter_app.value_get(&contents.json, "name")
	testing.expect_value(t, nerr, nil)
	defer sciter_app.value_clear(&name)
	name_text, _ := sciter_app.value_to_string(&name, context.temp_allocator)
	testing.expect_value(t, name_text, "odin")

	counts, cerr2 := sciter_app.value_get(&contents.json, "counts")
	testing.expect_value(t, cerr2, nil)
	defer sciter_app.value_clear(&counts)
	length, lerr := sciter_app.value_len(&counts)
	testing.expect_value(t, lerr, nil)
	testing.expect_value(t, length, 3)
}

// **HTML does not survive unchanged**, and this is the test that says exactly how it differs - which is
// the finding the example exists to carry.
@(test)
test_html_comes_back_wrapped_and_nul_terminated :: proc(t: ^testing.T) {
	window, ok := test_view(t)
	if !ok {return}

	ORIGINAL :: "<b>bold</b> and <i>italic</i>"
	fragment := sciter_app.value_from_string(ORIGINAL)
	defer sciter_app.value_clear(&fragment)

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

	// The NUL is not an HTML thing - the text flavour has it too, which is why `get_text` trims.
	wrote_text, terr := put_flavour(window, "text", &fragment)
	testing.expect_value(t, terr, nil)
	testing.expect(t, wrote_text, "the clipboard accepted the text flavour")
	plain, perr := read_clipboard(window, context.temp_allocator)
	testing.expect_value(t, perr, nil)
	defer sciter_app.value_clear(&plain.json)
	testing.expect(t, strings.contains(plain.text, "\x00"), "the text flavour carries the NUL too")

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
	result, err := sciter_app.eval(window, `await import("@sys")`)
	if err == nil {
		defer sciter_app.value_clear(&result)
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
