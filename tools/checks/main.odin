// The repository's static checks, in Odin, reading Odin.
//
//	odin run tools/checks -- <check> [args]
//
// One binary with subcommands rather than one program per check, for two reasons. `package sciter_app`
// is collected and parsed once and every check reads the same index - six separate programs would each
// re-read and re-parse the tree. And a check is one procedure here, so the shared vocabulary
// (`param_types`, `result_types`, `reaches`, `node_text`) is a call rather than a copy, which is what
// the Python originals could not have across six files without a shared module they also had to put on
// `sys.path` by hand in every recipe.
//
// Checks:
//
//	ownership       docs/rules.md section 4 - takes an allocator => yours to free, otherwise borrowed
//	affinity        docs/rules.md section 1 - every engine call goes through `engine()`
//	invariants      the Value ledger, the handle ledger, and `context =` in every `proc "system"`
//	api-coverage    docs/api.md mentions every exported procedure
//	doc-ownership   the owned/borrowed split in listings inside doc comments and guides
//	stats           the counts the documentation quotes about itself
//	parity          which C-API slots `sciter_app` reaches, against docs/parity-baseline.txt
//
// Each exits 0 on success and 1 with the findings on stderr, which is what the justfile recipes and CI
// already expect - these are drop-in replacements for the scripts in .github/scripts.
//
// **Run from the repository root.** `just` guarantees that, and the paths below assume it.
package checks

import "core:fmt"
import "core:os"

USAGE :: `usage: checks <check> [args]

  ownership                    ownership rule (docs/rules.md section 4)
  affinity                     thread-affinity rule (docs/rules.md section 1)
  invariants                   Value ledger, handle ledger, callback context
  api-coverage                 docs/api.md mentions every exported procedure
  doc-ownership [--self-test]  owned/borrowed split in doc-comment listings
  stats [--check]              suite and coverage counts
  parity [--check]             C-API slot coverage against the baseline
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	rest := args[1:]
	code: int
	switch args[0] {
	case "ownership":
		code = check_ownership()
	case "affinity":
		code = check_affinity()
	case "invariants":
		code = check_invariants()
	case "api-coverage":
		code = check_api_coverage(has_flag(rest, "--list"))
	case "doc-ownership":
		code = check_doc_ownership(has_flag(rest, "--self-test"), has_flag(rest, "--show-skipped"))
	case "stats":
		code = run_stats(has_flag(rest, "--check"), has_flag(rest, "--uncovered"))
	case "parity":
		code = run_parity(has_flag(rest, "--check"))
	case:
		fmt.eprintfln("unknown check %q", args[0])
		fmt.eprint(USAGE)
		os.exit(2)
	}
	os.exit(code)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for a in args {
		if a == flag {
			return true
		}
	}
	return false
}

// Load `package sciter_app` or die - every check but `parity`'s header half needs it, and a package
// that will not parse is not a finding to report, it is a broken tree.
sciter_app_index :: proc() -> Index {
	idx, ok := load_index("sciter_app")
	if !ok {
		os.exit(1)
	}
	return idx
}
