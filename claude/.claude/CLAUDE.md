# Global instructions

## Scratch / temp files

For any scratch, temporary, or intermediate files, write to the directory in
`$CLAUDE_CODE_TMPDIR` (resolve the env var at runtime; fall back to `/tmp` only
if it is unset). Never write scratch files into the project/repo working tree.

## Writing

@references/unslop.md applies to everything written here, replies and commit
messages alike
