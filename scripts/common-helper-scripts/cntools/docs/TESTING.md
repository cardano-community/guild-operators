# Testing the modular CNTools payload

Stage 3 tests prove that the deterministic metadata registry matches the
characterized legacy menu while every modular action remains inert and the
public legacy dispatcher stays authoritative. All Stage 0/1/2 compatibility,
transaction, and recovery coverage remains required.

Required static checks include:

- Bash syntax and ShellCheck for every shell member;
- byte-for-byte reconstruction of the characterized legacy logical body from
  the facade segments and ten fragments, plus independent syntax validation of
  every fragment boundary;
- the unchanged 121-function inventory, function replacement behavior,
  initialization globals and filesystem effects, repeated-source behavior,
  return statuses, and caller shell state;
- facade loading from repository, installed-public, and generation layouts
  with an arbitrary current directory;
- fail-closed handling of missing, extra, reordered, corrupt, symlinked,
  wrongly owned, or wrongly permissioned bundle members and any outer
  deployment journal, before legacy initialization;
- strict JSON parsing and metadata/schema validation;
- exact discovery of 69 metadata documents and 54 inert action stubs, yielding
  15 menus, 22 dispatcher-owned controls, and 90 deterministic options;
- byte-identical `--dump-menu` output against the frozen Stage 0 parity oracle,
  plus proof that diagnostics never execute an action or use ambient runtime
  context to filter the static model;
- installed-diagnostic rejection before generation sourcing when outer source
  receipt, deployment metadata, implementation inventory, versions, owner,
  modes, paths, hashes, journal state, or clean-shell assumptions are invalid;
- lock acquisition followed by repeated outer authority and complete-generation
  validation before trusted lifecycle, bootstrap, or registry code is loaded;
- exact payload paths, immutable modes, bundle identity, and SHA-256 inventory;
- atomic publication or exact reuse of a complete legacy bundle before its
  facade, retention of older valid bundle IDs, and rollback/recovery at every
  publication boundary;
- reader isolation proving the facade is the first ordinary forward payload
  member, remains journal-refusing throughout activation, and is restored last
  only after every other rollback leg succeeds;
- hard-interruption recovery on both sides of bundle and generation directory
  renames, including a temporarily mode-`0755` object root, atomic retraction
  to durable staging, and fail-closed retry when a transaction-created parent
  is nonempty or otherwise unsafe;
- exact generation reuse, without inode, timestamp, or byte changes, when a
  new source revision contains the same CNTools payload;
- validation of only the exact schema-1 Stage 1 19/20, schema-2 Stage 2 29/30,
  and schema-3 Stage 3 151/152 generation shapes, including rollback from a new
  generation to an old one and forward again, plus bundle-ID A to bundle-ID B
  and back without sourcing code from any inspected candidate;
- cross-version recovery with exact six-field Stage 1/2 durable records and the
  exact ten-field Stage 3 record ending in `3,151,3,152`, with truncated,
  extended, and hybrid records rejected before mutation;
- rejection of unknown files, symlinks, traversal, duplicate metadata, unknown
  libraries, dependency cycles, and missing action entrypoints;
- configuration fixtures covering unknown/duplicate keys, shell syntax,
  expansions, malformed values, unsafe runtime modes/owners, and safe legacy
  literal migration; and
- proof that sourcing each new core/library/action file creates no runtime
  effects. The transitional facade's legacy initialization is compared with
  the characterized monolith instead of being treated as effect-free.

Canary activation uses isolated targets only. It must validate the candidate,
switch the canary reference atomically, prove the launcher resolves one
generation, and roll back to the preceding generation. Production continues to
run the characterized legacy dispatcher until the later explicit gate.

Deployment coverage must use the dispatcher transaction. The direct cnode and
Dingo profile fallbacks are expected to refuse the split payload; a test must
not make that unsupported path appear to install only the facade or individual
fragments successfully.

Workflow equivalence remains governed by the Stage 0 fixtures. Every extracted
action adds success, cancellation, retry, failure, and persistent-artifact
coverage before its dispatch path changes.
