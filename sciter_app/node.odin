// Nodes: the half of the DOM that is not elements.
//
// `dom.odin` walks elements, which is what an application wants nearly all of the time. A document is
// really a tree of *nodes*, though - text and comments are nodes with no element wrapping them - and
// there are jobs that need that view: reading the text around an inline `<b>` without flattening it,
// inserting a text node between two elements, or walking a document exactly as it is written.
//
// Two rules, both from the C API and neither hidden here:
//
//   - **node handles are not reference counted on the way out.** `sciter-x-dom.h` says it plainly:
//     "node handles returned by functions below are not AddRef'ed". A handle is valid while the node
//     is in the document, and holding one past that needs `node_add_ref` / `node_release` - the same
//     arrangement as `use_element`, with a different spelling upstream.
//   - **a node you made carries one reference, and only `node_release` discharges it.** `make_text_node`
//     and `make_comment_node` hand back an `Owned_Node`. Putting it in a document does **not** settle
//     the debt - measured, see `node_insert` - so an insert without a release is a leak.
package sciter_app

import sciter ".."

// ---------------------------------------------------------------------------------------------------
// Lifetime

// A node you hold a reference to, and therefore **owe a `node_release`**. It comes from
// `make_text_node`, `make_comment_node` and `node_add_ref`, and from nowhere else - notably **not** from
// `node_remove(finalize = false)`, which is where the element API mints one and this one does not.
//
// Separate from `Node` for the reason `Owned_Element` is separate from `Element`, and the numbers are
// the same shape. Measured on 6.0.4.9, 2000 iterations of a 100 kB text node:
//
//   - made and released: **+200 kB** RSS. Balanced.
//   - made and never released: **+400 MB**. The leak.
//   - made, inserted into the document, removed with `finalize = true`, never released: **+400 MB**.
//     The document does not take the reference over, which is the thing this type exists to say.
//
// The other direction is worse, as everywhere else in this API: one spurious `node_release` on a
// borrowed node answers `.OK`, leaves the document readable, and then segfaults when the document is
// torn down - inside `html::element::~element()`, freeing a node whose count this call already took to
// zero. Nothing points at the release site by then.
//
// `node_release` therefore takes this type and nothing else, and `borrow_node` is the free cast for
// everything that reads or moves it.
Owned_Node :: distinct Node

// Views an owned node as a borrowed one, for the calls that read or write it.
//
//	made := sciter_app.make_text_node(" appended") or_return
//	defer sciter_app.node_release(made)
//	sciter_app.node_set_text(sciter_app.borrow_node(made), "changed") or_return
//
// It takes no reference and gives none up - it is a cast, and the `Owned_Node` still owes the release.
borrow_node :: proc(node: Owned_Node) -> Node {
	return Node(node)
}

// Takes a reference to a borrowed node, so the engine will not free it while the handle is held.
//
// The result is the thing that owes a `node_release`; the `Node` that went in is still borrowed and
// still must not be released. Not needed for a handle used and dropped inside one callback.
node_add_ref :: proc(node: Node, loc := #caller_location) -> (owned: Owned_Node, err: Error) {
	if err = dom_err(engine().SciterNodeAddRef(sciter.Hnode(node))); err != nil {
		return nil, err
	}
	track_acquire(.Node, rawptr(node), loc)
	return Owned_Node(node), nil
}

// Gives back one reference. Pairs with exactly one `make_text_node`, `make_comment_node` or
// `node_add_ref` - see `Owned_Node` for what the two ways of getting the count wrong cost.
node_release :: proc(node: Owned_Node) -> Error {
	err := dom_err(engine().SciterNodeRelease(sciter.Hnode(node)))
	if err == nil {
		track_release(.Node, rawptr(node))
	}
	return err
}

// ---------------------------------------------------------------------------------------------------
// Crossing between the two views

// The node view of an element. Every element is a node; the reverse is not true.
node_from_element :: proc(element: Element) -> (node: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodeCastFromElement(sciter.Helement(element), &hn)) or_return
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// The element a node is, or `.Not_Found` when it is a text or comment node. Check `node_type` first if
// the distinction matters more than the failure.
node_to_element :: proc(node: Node) -> (element: Element, err: Error) {
	he: sciter.Helement
	dom_err(engine().SciterNodeCastToElement(sciter.Hnode(node), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

node_type :: proc(node: Node) -> (type: sciter.Node_Type, err: Error) {
	dom_err(engine().SciterNodeType(sciter.Hnode(node), &type)) or_return
	return type, nil
}

// ---------------------------------------------------------------------------------------------------
// Nodes as Values
//
// The node half of `element_to_value` / `element_from_value`, and the only way to hand script a text
// or comment node. The rules are the same: the Value owns a reference, the handle that comes back is
// borrowed, and the wrapped Value is a `.RESOURCE` that renders as `""`.
//
// The two directions are not symmetric, because an element *is* a node and a text node is not an
// element: `node_from_value` accepts a Value made by either `node_to_value` or `element_to_value`,
// while `element_from_value` fails with `.OPERATION_FAILED` on a text node's Value.

node_to_value :: proc(node: Node) -> (v: Value, err: Error) {
	dom_err(sciter.Scdom_Result(engine().SciterNodeWrap(&v, sciter.Hnode(node)))) or_return
	return tracked(v), nil
}

node_from_value :: proc(v: ^Value) -> (node: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(sciter.Scdom_Result(engine().SciterNodeUnwrap(v, &hn))) or_return
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// ---------------------------------------------------------------------------------------------------
// Traversal
//
// Each returns `.Not_Found` at the end of the walk rather than a nil handle, so the error is the
// termination condition:
//
//	for child, err := node_first_child(root); err == nil; child, err = node_next_sibling(child) {
//		// ...
//	}

// **This counts text and comment nodes too, so it is not `child_count(element)`.** A `<ul>` written
// across several lines has a whitespace text node between every pair of `<li>`s: five node children
// against two element children, measured. That difference is the first thing the node view surprises
// people with, and indexing with `node_child` on the assumption that children are elements is how it
// bites.
// A position among a node's children, counting text and comment nodes as well as elements. `distinct`
// from `Child_Index` because they are two numberings of the same parent and the difference is exactly
// what the comment above warns about: handing one of these to `child` finds the wrong element, or none.
//
// There is no conversion between the two - the counts differ per parent, so going from one to the other
// means walking the children, not casting.
Node_Index :: distinct int

node_child_count :: proc(node: Node) -> (n: Node_Index, err: Error) {
	count: u32
	dom_err(engine().SciterNodeChildrenCount(sciter.Hnode(node), &count)) or_return
	return Node_Index(count), nil
}

// The nth child. Unlike the rest of the walk, an index past the end is `.INVALID_PARAMETER` rather
// than `.Not_Found` - it is a mistake, not the end of anything.
node_child :: proc(node: Node, n: Node_Index) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodeNthChild(sciter.Hnode(node), u32(n), &hn)) or_return
	return found_node(hn)
}

node_first_child :: proc(node: Node) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodeFirstChild(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_last_child :: proc(node: Node) -> (child: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodeLastChild(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_next_sibling :: proc(node: Node) -> (sibling: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodeNextSibling(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

node_prev_sibling :: proc(node: Node) -> (sibling: Node, err: Error) {
	hn: sciter.Hnode
	dom_err(engine().SciterNodePrevSibling(sciter.Hnode(node), &hn)) or_return
	return found_node(hn)
}

// The parent, which is always an element - only an element can contain nodes.
node_parent :: proc(node: Node) -> (parent: Element, err: Error) {
	he: sciter.Helement
	dom_err(engine().SciterNodeParent(sciter.Hnode(node), &he)) or_return
	if he == nil {
		return nil, .Not_Found
	}
	return Element(he), nil
}

// The engine reports "there is no such node" as OK plus a null handle. Every traversal above turns
// that into `.Not_Found`, so a walk terminates on the error rather than on a nil check.
@(private = "file")
found_node :: proc(hn: sciter.Hnode) -> (node: Node, err: Error) {
	if hn == nil {
		return nil, .Not_Found
	}
	return Node(hn), nil
}

// ---------------------------------------------------------------------------------------------------
// Text

// The text of a text or comment node, allocated in `allocator`. On an element node the engine reports
// nothing - use `text(element)` for that.
node_text :: proc(node: Node, allocator := context.allocator) -> (text: string, err: Error) {
	sink := String_Sink {
		ctx       = context,
		allocator = allocator,
	}
	dom_err(engine().SciterNodeGetText(sciter.Hnode(node), wide_receiver, &sink)) or_return
	return sink.out, nil
}

// Replaces the text of a text or comment node.
//
// **On an element node it answers `.OK` and does nothing.** Not an error, not a partial edit - the
// markup, the children and the text all come back unchanged, on an element with inline children and on
// one holding a single word alike. It pairs with `node_text`, which likewise reports `""` for an
// element; both work on the node's own text, and an element has none.
//
// `set_text(element)` is the call that replaces an element's content. This one edits the words around
// an inline child without disturbing the child, which `set_text` cannot do.
node_set_text :: proc(node: Node, text: string) -> Error {
	w := utf16_from_string(text, context.temp_allocator)
	return dom_err(engine().SciterNodeSetText(sciter.Hnode(node), raw_data(w), u32(len(w) - 1)))
}

// ---------------------------------------------------------------------------------------------------
// Creating and moving nodes

// A detached text node, carrying one reference: **`node_release` it when you are done, whether or not
// you insert it**.
//
// `found_node` rather than a bare cast, as everywhere else here: OK plus a null handle would otherwise
// hand back a nil Node that the file's own ownership rule then tells the caller to insert or release.
make_text_node :: proc(text: string, loc := #caller_location) -> (node: Owned_Node, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	hn: sciter.Hnode
	dom_err(engine().SciterCreateTextNode(raw_data(w), u32(len(w) - 1), &hn)) or_return
	track_acquire(.Node, rawptr(hn), loc)
	found := found_node(hn) or_return
	return Owned_Node(found), nil
}

// A detached comment node. Same ownership as `make_text_node`.
make_comment_node :: proc(text: string, loc := #caller_location) -> (node: Owned_Node, err: Error) {
	w := utf16_from_string(text, context.temp_allocator)
	hn: sciter.Hnode
	dom_err(engine().SciterCreateCommentNode(raw_data(w), u32(len(w) - 1), &hn)) or_return
	track_acquire(.Node, rawptr(hn), loc)
	found := found_node(hn) or_return
	return Owned_Node(found), nil
}

// Puts `what` into the document, positioned relative to `node`: `.BEFORE`, `.AFTER`, `.APPEND` (as the
// last child of `node`) or `.PREPEND` (as the first).
//
// **The document does not take your reference.** This is the correction that `Owned_Node` exists to
// make: the doc comment here used to say ownership transferred, and the wrapper told the resource
// ledger the same thing, so a node inserted and never released was a leak that the leak gate was
// explicitly instructed to ignore. Measured, 2000 iterations of a 100 kB node: inserted and released,
// **+200 kB**; inserted and not released, **+400 MB** - and that is with the node removed and finalized
// afterwards, so not even destroying it settles the reference. Release it, or leak it.
//
// `what` is an `Owned_Node` because only a detached node can be inserted at all, and a detached node is
// always one you own. **A node can be inserted once and never again.** A second insertion of the same
// handle - into another parent, or anywhere at all - is `.INVALID_HANDLE`, and so is inserting a node
// that is already in the document or one taken back out with `node_remove`. See there.
node_insert :: proc(node: Node, where_: sciter.Node_Ins_Target, what: Owned_Node) -> Error {
	return dom_err(engine().SciterNodeInsert(sciter.Hnode(node), u32(where_), sciter.Hnode(what)))
}

// Takes the node out of the document. `finalize = true` destroys it.
//
// **`finalize = false` does not give you a node you can put back.** The name and the C header both
// suggest a detach-and-reattach, which would be how a subtree is moved; measured, it is not. The handle
// stays *readable* afterwards - `node_type` and `node_text` still answer, and `node_parent` reports
// `.Not_Found` - but every insertion of it fails with `.INVALID_HANDLE`: into the old parent, into a
// new one, relative to a sibling, and with or without a `node_add_ref` taken first.
//
// So there is no move. To relocate content, read it out (`html`, or `node_text`) and build a new node
// from it - which is what `dom_walk`'s node tests do.
//
// **It does not mint an `Owned_Node` either**, which is where nodes and elements part company:
// `remove_element(finalize = false)` hands back an owned element, and this hands back nothing.
// Measured on a node the document made and this call detached with `finalize = false`: a `node_release`
// on it is the borrowed-handle under-flow, `.OK` at the call and a segfault at teardown. Only
// `make_text_node`, `make_comment_node` and `node_add_ref` produce something to release.
node_remove :: proc(node: Node, finalize := true) -> Error {
	return dom_err(engine().SciterNodeRemove(sciter.Hnode(node), b32(finalize)))
}
