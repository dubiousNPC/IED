# IED sweep — bugs, syntax, stray references, pcall audit

Same sweep run on CAKE, applied here. **No functional bug of CAKE's kind was
found** — IED already resolves its mesh path correctly — but six `pcall`s came
out, one of which had already hidden a real bug in this very file.

---

## The mesh-path question: IED is clean

CAKE broke because it handed `addVfx` a raw plugin `MODL` string
(`RV\Ashmask1.nif`) instead of a VFS path (`meshes/rv/ashmask1.nif`), and
attached nothing at all, silently.

IED does not have this problem. It reads `rec.model` off the record at runtime,
which Cod3x documents as a **VFS path**, and `normPath` — lowercase, backslash
to forward slash — is a no-op on a string that is already in that form.

`normPath` is kept anyway, as a guard for a caller that ever passes a raw MODL
string, and the reason is now written down next to it.

### One weakness that was there

`resolveMesh` existence-checked only the `_sh` sheathed variant and returned the
base path unchecked. A record whose mesh is not in the VFS therefore produced a
dead path, which the `pcall` around `addVfx` then swallowed — CAKE's failure
mode exactly, one step away. It now checks the base path too and **prints**
when it is missing:

```
[IED] mesh not in VFS, skipping: meshes/w/ghost.nif
```

Reported, not swallowed. A record with a missing mesh is a broken install or an
absent master, and it should say so once rather than fail invisibly on every
rebuild.

---

## pcall audit: 7 found, 6 removed, 1 kept

### Removed

| Call | Why the pcall was wrong |
|---|---|
| `types.Weapon.record(item)` | Every caller has already established this is a weapon — either from `inv:getAll(types.Weapon)` or an `objectIsInstance` check. It cannot fail on one. |
| `types.Armor.record(item)` | Same. |
| `anim.removeVfx` | Removing an id that was never added is a no-op. |
| `anim.addVfx` | **The CAKE bug's hiding place.** Mesh and bone are both validated immediately above; a failure here means one of those checks is wrong, which is precisely what must not be silent. |
| `types.Actor.getEquipment` | Documented, on a valid actor. |
| `types.Actor.getStance` | Same. `local isDrawn = getStance(actor) == STANCE.Weapon` now reads as one line. |

The `getEquipment` one is worth calling out. The file's own header records that
the original called `types.Actor.equipment`, **a function that does not exist**,
and that the surrounding `pcall` hid it completely — the mod silently believed
nothing was ever equipped. That is the argument against the pattern, made by
this file about itself, so the pcall had to go too.

### Kept

**`AnimRefresh_v2.lua` — `pcall(callback, mode, previous)`.** Calls into
third-party subscriber code. One subscriber throwing must not stop delivery to
the others, and the error is printed with the subscriber's key rather than
swallowed. Isolating a boundary you do not control is the legitimate use.

---

## Other sweeps

| Sweep | Result |
|---|---|
| `luacheck.py` (syntax, liblua5.4) | 5 files / 7 files, **0 failures** |
| `check_names.py` (undefined names, unused requires) | **clean** |
| `api_sweep.py` (every `module.member` vs Cod3x stubs) | **nothing unrecognised** |
| unused locals / dead module fields | 2 flagged, both legitimate — see below |

`M.sharedBones` and `M.handler` are reported as unreferenced by the mod's own
code. Both are deliberate test surface: `tools/test_ied_lite.lua` calls
`bones.sharedBones()` to assert the shared-bone set is computed rather than
listed, and drives `common.handler()` directly. Neither is a stray reference.

---

## Tests

10/10 pass (`python3 tools/luarun.py tools/test_ied_lite.lua`). Three are new,
covering the class of bug this sweep was looking for:

```
a VFS model path attaches
prefers the _sh sheathed variant when it exists
a model missing from the VFS is skipped, not passed to addVfx
```

The mock `addVfx` now **asserts** its argument is a VFS path — `meshes/`
prefixed, no backslashes — and that the file is in the mock VFS at all. The old
mock returned `m/<id>.nif` for `record.model` and accepted anything, so it could
not have caught this. A mock that accepts everything tests nothing.

The sheathing-clash assertions from the previous pass are unchanged and still
pass, including the counter that trips whenever two meshes land on one bone.
